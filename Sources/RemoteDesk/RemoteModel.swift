import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import RemoteCore

@MainActor @Observable
final class RemoteModel {
    struct Activity: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    struct HardwarePress {
        enum Phase: Equatable {
            case down, holding, shortPress, longPress
        }

        let key: String
        let phase: Phase
    }

    private(set) var config = Configuration()
    private(set) var devices: [DeviceID] = []
    private(set) var ambiguousDevices: Set<DeviceID> = []
    private(set) var monitorState: InputMonitorState = .permission
    private(set) var learning: String?
    private(set) var activity: [Activity] = []
    private(set) var feedback: String?
    private(set) var error: String?
    private(set) var storageError: String?
    private(set) var isRunning = false
    private(set) var canPost = false
    private(set) var canUseAccessibility = false
    private(set) var hardwarePress: HardwarePress?
    private var virtualPulse: String?
    var pulse: String? { hardwarePress?.key ?? virtualPulse }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                cancelLearning()
                cancelDictation()
                cancelPowerPress()
                onDismissMedia?()
            }
        }
    }
    private(set) var isDiagnosing = false
    var slot = "ok"

    let dictation: DictationController
    private var dictationInput: (code: InputCode, origin: RemoteInputOrigin?)?
    private let hid: any RemoteInputSource
    private let storeURL: URL
    private let runAction: @MainActor (AgentAction, AppTarget?) async throws -> Void
    private var draftActions: [String: AgentAction]?
    private var draftRemotes: [DeviceID: RemoteMap] = [:]
    private var canSave = true
    private var pulseTask: Task<Void, Never>?
    private var hardwareTask: Task<Void, Never>?
    private var hardwareDown: (code: InputCode, origin: RemoteInputOrigin?, time: ContinuousClock.Instant)?
    private var learningTask: Task<Void, Never>?
    private let powerHoldDelay: Duration
    private var powerTask: Task<Void, Never>?
    private var powerPress: (code: InputCode, origin: RemoteInputOrigin?, started: ContinuousClock.Instant, fired: Bool)?
    private var homePressOrigins: Set<RemoteInputOrigin> = []
    var onShowMedia: (() -> Void)?
    var onSwitchApps: (() -> Void)?
    var onMediaKey: ((String, Bool) -> Bool)?
    var onDismissMedia: (() -> Void)?

    convenience init() {
        let directory = URL.applicationSupportDirectory.appending(path: "RemoteDesk", directoryHint: .isDirectory)
        self.init(hid: HIDMonitor(), storeURL: directory.appending(path: "configuration.json"),
                  runAction: AgentRunner.run)
    }

    init(hid: any RemoteInputSource, storeURL: URL,
         dictation: DictationController = DictationController(),
         powerHoldDelay: Duration = .milliseconds(600),
         runAction: @escaping @MainActor (AgentAction, AppTarget?) async throws -> Void) {
        self.dictation = dictation
        self.hid = hid
        self.storeURL = storeURL
        self.runAction = runAction
        self.powerHoldDelay = powerHoldDelay
        var didUpgrade = false
        do {
            let original = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(Configuration.self, from: original)
            if decoded.version == Configuration.currentVersion {
                config = decoded
            } else if (1..<Configuration.currentVersion).contains(decoded.version) {
                config = decoded
                config.upgradeLegacy()
                do {
                    try Self.backUp(original, version: decoded.version, at: storeURL)
                    didUpgrade = true
                } catch {
                    canSave = false
                    storageError = "无法备份旧配置，本次更改不会覆盖原文件。"
                }
            } else {
                canSave = false
                storageError = "配置来自其他版本，本次更改不会覆盖原文件。"
            }
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // The initial configuration is saved after the first edit.
        } catch {
            canSave = false
            storageError = "无法读取配置，本次更改不会覆盖原文件。"
        }
        if config.selectedDevice?.isSupportedRemote != true { config.selectedDevice = nil }
        hid.selectedDevice = config.selectedDevice
        hid.onDevices = { [weak self] devices in self?.updateDevices(devices) }
        hid.onAmbiguousDevices = { [weak self] devices in self?.updateAmbiguity(devices) }
        hid.onMonitorState = { [weak self] state in self?.updateMonitorState(state) }
        hid.onEvent = { [weak self] device, event in self?.receive(device, event) }
        if didUpgrade { save() }
    }

    private static func backUp(_ original: Data, version: Int, at storeURL: URL) throws {
        let backup = storeURL.appendingPathExtension("v\(version).backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            if (try? Data(contentsOf: backup)) == original { return }
            try original.write(to: backup.appendingPathExtension(UUID().uuidString), options: .atomic)
        } else {
            try original.write(to: backup, options: .atomic)
        }
    }

    var connectedDevice: DeviceID? { config.selectedDevice.flatMap { devices.contains($0) ? $0 : nil } }
    var connected: Bool { connectedDevice != nil }
    var hasConnectedXiaomi: Bool { connectedDevice?.isSupportedRemote == true }
    var canReadKeys: Bool {
        connected && monitorState == .listening && !(connectedDevice.map(ambiguousDevices.contains) ?? false)
    }
    var selectableDevices: [DeviceID] { devices.filter { !ambiguousDevices.contains($0) } }
    var profile: AgentProfile? { config.activeAgent }
    var profiles: [AgentProfile] { [.defaults] + config.agents.filter { $0.id != AgentProfile.defaults.id } }
    var needsProfileName: Bool { profile?.id == AgentProfile.defaults.id && draftActions != nil }
    var editableActions: [String: AgentAction] { draftActions ?? profile?.actions ?? [:] }
    var editableRemote: RemoteMap? {
        guard let saved = config.activeRemote else { return nil }
        return draftRemotes[saved.device] ?? saved
    }
    var hasConfigurationChanges: Bool { draftActions != nil || !draftRemotes.isEmpty }
    var connectionStatus: String {
        guard connected else { return ambiguousDevices.isEmpty ? "未连接" : "已连接 · 设备无法区分" }
        if monitorState == .ambiguous || connectedDevice.map(ambiguousDevices.contains) == true { return "已连接 · 设备无法区分" }
        guard canReadKeys else { return "已连接 · 未监听" }
        if isDiagnosing { return "已连接 · 诊断中" }
        return isEnabled ? "已连接" : "已连接 · 已暂停"
    }

    func refreshPermissions() {
        updateMonitorState(hid.refresh())
        canPost = CGPreflightPostEventAccess()
        canUseAccessibility = AXIsProcessTrusted()
        if !canUseAccessibility { cancelDictation() }
    }

    private func updateMonitorState(_ state: InputMonitorState) {
        monitorState = state
        if !canReadKeys {
            homePressOrigins.removeAll()
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelPowerPress()
            onDismissMedia?()
        }
    }

    private func updateDevices(_ devices: [DeviceID]) {
        self.devices = devices.filter(\.isSupportedRemote)
        updateSelection()
    }

    private func updateAmbiguity(_ devices: Set<DeviceID>) {
        ambiguousDevices = devices
        if !canReadKeys {
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelPowerPress()
            onDismissMedia?()
        }
    }

    private func updateSelection() {
        if (connectedDevice == nil || connectedDevice.map(ambiguousDevices.contains) == true),
           selectableDevices.count == 1, let device = selectableDevices.first {
            selectDevice(device)
        }
        if !canReadKeys {
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelPowerPress()
            onDismissMedia?()
        }
    }

    func requestListen() {
        if !CGRequestListenEventAccess() { openPrivacy("Privacy_ListenEvent") }
        refreshPermissions()
    }

    func requestPost() {
        if !CGRequestPostEventAccess() { openPrivacy("Privacy_Accessibility") }
        refreshPermissions()
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBluetooth() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func selectDevice(_ id: DeviceID) {
        guard id.isSupportedRemote, devices.contains(id), !ambiguousDevices.contains(id),
              config.selectedDevice != id else { return }
        homePressOrigins.removeAll()
        cancelLearning()
        cancelDictation()
        clearHardwarePress()
        cancelPowerPress()
        onDismissMedia?()
        config.selectDevice(id)
        hid.selectedDevice = id
        slot = "ok"
        feedback = nil
        error = nil
        activity = []
        save()
    }

    func selectSlot(_ slot: String) {
        if self.slot != slot { cancelLearning() }
        self.slot = slot
    }

    func startLearning() {
        guard canReadKeys, isEnabled, !isDiagnosing else { return }
        cancelLearning()
        cancelDictation()
        cancelPowerPress()
        onDismissMedia?()
        learning = slot
        feedback = nil
        error = nil
        learningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.cancelLearning()
            self?.error = "未收到按键。检查遥控器是否已连接，然后重试。"
        }
    }

    func cancelLearning() {
        learningTask?.cancel()
        learningTask = nil
        learning = nil
    }

    private func updateRemoteDraft(_ edit: (inout RemoteMap) -> Void) {
        guard let saved = config.activeRemote, var draft = editableRemote else { return }
        edit(&draft)
        draftRemotes[saved.device] = draft == saved ? nil : draft
    }

    func setAction(_ action: AgentAction?, for slot: String) {
        guard let saved = profile?.actions,
              slot == "power-long" || RemoteKey.xiaomi.contains(where: { $0.id == slot }) else { return }
        cancelLearning()
        var actions = editableActions
        actions[slot] = action
        draftActions = actions == saved ? nil : actions
        feedback = nil
        error = nil
    }

    func restoreDefaultActions() {
        cancelLearning()
        let defaults = AgentProfile.defaults.actions
        draftActions = profile?.actions == defaults ? nil : defaults
        feedback = draftActions == nil ? "当前已使用默认按键。" : "已载入默认按键，保存后生效。"
        error = nil
    }

    @discardableResult
    func saveConfigurationChanges(as name: String? = nil) -> Bool {
        guard hasConfigurationChanges, learning == nil else { return false }
        var updated = config
        if let draftActions {
            if needsProfileName {
                guard let name = availableProfileName(name) else { return false }
                let copy = AgentProfile(name: name, target: AgentProfile.defaults.target, actions: draftActions)
                updated.agents.append(copy)
                updated.activeAgentID = copy.id
            } else if let index = updated.agents.firstIndex(where: { $0.id == updated.activeAgentID }) {
                updated.agents[index].actions = draftActions
            }
        }
        updated.remotes = updated.remotes.map { draftRemotes[$0.device] ?? $0 }
        guard save(updated) else { return false }
        cancelPowerPress()
        cancelDictation()
        onDismissMedia?()
        draftActions = nil
        draftRemotes = [:]
        error = nil
        feedback = "配置已保存"
        return true
    }

    @discardableResult
    func selectProfile(_ id: String, discardingDraft: Bool = false) -> Bool {
        guard profiles.contains(where: { $0.id == id }), profile?.id != id,
              discardingDraft || !hasConfigurationChanges else { return false }
        var updated = config
        updated.activeAgentID = id
        guard save(updated) else { return false }
        discardConfigurationChanges()
        cancelPowerPress()
        cancelDictation()
        onDismissMedia?()
        return true
    }

    @discardableResult
    func importProfile(_ archive: ProfileArchive, as name: String, discardingDraft: Bool) -> Bool {
        guard discardingDraft || !hasConfigurationChanges, let name = availableProfileName(name) else { return false }
        let copy = AgentProfile(name: name, target: AgentProfile.defaults.target, actions: archive.actions)
        var updated = config
        updated.agents.append(copy)
        updated.activeAgentID = copy.id
        guard save(updated) else { return false }
        discardConfigurationChanges()
        cancelPowerPress()
        cancelDictation()
        onDismissMedia?()
        feedback = "配置已导入"
        return true
    }

    private func availableProfileName(_ proposed: String?) -> String? {
        let name = proposed?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
        guard !name.isEmpty else {
            error = "请输入配置名称。"
            return nil
        }
        guard !profiles.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased() == name.lowercased() }) else {
            error = "此配置名称已存在。"
            return nil
        }
        return name
    }

    func discardConfigurationChanges() {
        cancelLearning()
        draftActions = nil
        draftRemotes = [:]
        feedback = nil
        error = nil
    }

    func setDiagnosing(_ active: Bool) {
        if active {
            cancelLearning()
            cancelDictation()
            cancelPowerPress()
            onDismissMedia?()
        }
        isDiagnosing = active
    }

    func pressVirtualKey(_ id: String) {
        guard !isDiagnosing, learning == nil, !isRunning, !dictation.phase.active,
              RemoteKey.xiaomi.contains(where: { $0.id == id }) else { return }
        flash(id)
        feedback = nil
        error = nil
        guard canReadKeys else { return }
        guard isEnabled else {
            feedback = "遥控触发已暂停"
            return
        }
        if onMediaKey?(id, false) == true { return }
        guard let action = profile?.actions[id] else {
            feedback = "此键尚未分配动作"
            return
        }
        if action == .dictation {
            feedback = "请按住实体语音键开始听写。"
        } else {
            perform(action)
        }
    }

    private func receive(_ device: DeviceID, _ event: RemoteInputEvent) {
        guard config.selectedDevice == device, canReadKeys else { return }
        switch event {
        case let .pressed(input, origin):
            receivePress(input, slot: config.match(device: device, input: input) ?? input.xiaomi2ProSlot, origin: origin)
        case let .released(input, origin):
            if let origin { homePressOrigins.remove(origin) }
            let slot = config.match(device: device, input: input) ?? input.xiaomi2ProSlot
            let name = slot.flatMap { id in
                RemoteKey.xiaomi.first { $0.id == id }?.name
            }
            record("松开 · \(name.map { $0 + " · " } ?? "")\(input.label)")
            finishHardwarePress(input, origin: origin)
            finishPowerPress(input, origin: origin)
            if let held = dictationInput, held.code == input, held.origin == origin {
                dictation.release()
                if !dictation.phase.active { dictationInput = nil }
            }
        case let .replaced(input, origin):
            homePressOrigins.remove(origin)
            if powerPress?.code == input, powerPress?.origin == origin { cancelPowerPress() }
            if let down = hardwareDown, down.code == input, down.origin == origin { clearHardwarePress() }
            if let held = dictationInput, held.code == input, held.origin == origin {
                cancelDictation()
            }
        case let .endpointClosed(endpoint):
            homePressOrigins = homePressOrigins.filter { $0.endpoint != endpoint }
            if powerPress?.origin?.endpoint == endpoint { cancelPowerPress() }
            if hardwareDown?.origin?.endpoint == endpoint { clearHardwarePress() }
            if dictationInput?.origin?.endpoint == endpoint { cancelDictation() }
        }
    }

    private func receivePress(_ input: InputCode, slot knownSlot: String?, origin: RemoteInputOrigin?) {
        let visibleSlot = knownSlot.flatMap { candidate in RemoteKey.xiaomi.first { $0.id == candidate } }
        record("按下 · \(visibleSlot.map { $0.name + " · " } ?? "")\(input.label)")

        if let key = learning {
            cancelLearning()
            let priorSlot = editableRemote?.slot(for: input)
            updateRemoteDraft { $0.learn(input, as: key) }
            let name = RemoteKey.xiaomi.first { $0.id == key }?.name ?? key
            feedback = priorSlot != nil && priorSlot != key
                ? "信号已移到「\(name)」，保存后生效。"
                : "已收到「\(name)」的按键信号，保存后生效。"
            showHardwarePress(key, code: input, origin: origin)
            return
        }
        guard let visibleSlot else { return }
        // The RC003 reports Home through both its keyboard array and a discrete element.
        if visibleSlot.id == "home", input.xiaomi2ProSlot == "home", let origin {
            let wasHeld = !homePressOrigins.isEmpty
            homePressOrigins.insert(origin)
            guard !wasHeld else { return }
        }
        showHardwarePress(visibleSlot.id, code: input, origin: origin)
        guard isEnabled, !isDiagnosing, !isRunning, !dictation.phase.active else { return }
        if onMediaKey?(visibleSlot.id, input.matchesNavigationKey(visibleSlot.id)) == true { return }
        if visibleSlot.id == "power" {
            startPowerPress(input, origin: origin)
            return
        }
        guard let action = profile?.actions[visibleSlot.id] else { return }
        switch action {
        case let .foregroundKey(shortcut) where input.isNativeKeyboardShortcut(shortcut): return
        case .volumeUp where input.isNativeVolume(up: true): return
        case .volumeDown where input.isNativeVolume(up: false): return
        default: break
        }
        if action == .dictation {
            feedback = nil
            error = nil
            // Xiaomi's mic key is delivered to ChatGPT as a real keyboard F5.
            // Let ChatGPT handle both edges of its configured dictation shortcut.
            if input.isKeyboardF5 { return }
            dictationInput = (input, origin)
            dictation.press()
        } else {
            perform(action)
        }
    }

    func clearActivity() {
        activity.removeAll(keepingCapacity: true)
    }

    func reportError(_ message: String) { error = message }

    private func record(_ signal: String) {
        activity.insert(Activity(time: .now, text: signal), at: 0)
        if activity.count > 20 { activity.removeLast() }
    }

    private func cancelDictation() {
        dictationInput = nil
        dictation.cancel("听写已取消，未发送。")
    }

    private func startPowerPress(_ code: InputCode, origin: RemoteInputOrigin?) {
        guard powerPress == nil else { return }
        let started = ContinuousClock.now
        powerPress = (code, origin, started, false)
        powerTask = Task { [weak self, powerHoldDelay] in
            do { try await Task.sleep(until: started.advanced(by: powerHoldDelay), clock: .continuous) }
            catch { return }
            self?.fireLongPowerPress()
        }
    }

    private func fireLongPowerPress() {
        guard powerPress?.fired == false else { return }
        powerPress?.fired = true
        runPowerAction("power-long")
    }

    private func finishPowerPress(_ code: InputCode, origin: RemoteInputOrigin?) {
        guard let press = powerPress, press.code == code, press.origin == origin else { return }
        defer { cancelPowerPress() }
        if press.started.duration(to: .now) >= powerHoldDelay || press.fired {
            fireLongPowerPress()
        } else {
            runPowerAction("power")
        }
    }

    private func runPowerAction(_ slot: String) {
        guard isEnabled, canReadKeys, !isDiagnosing, learning == nil, !dictation.phase.active,
              let action = profile?.actions[slot] else { return }
        perform(action)
    }

    private func cancelPowerPress() {
        powerTask?.cancel()
        powerTask = nil
        powerPress = nil
    }

    private func showHardwarePress(_ key: String, code: InputCode, origin: RemoteInputOrigin?) {
        if let down = hardwareDown, down.code == code, down.origin == origin { return }
        hardwareTask?.cancel()
        let time = ContinuousClock.now
        let holdDelay = key == "power" ? powerHoldDelay : dictation.holdDelay
        hardwareDown = (code, origin, time)
        hardwarePress = HardwarePress(key: key, phase: .down)
        hardwareTask = Task { [weak self] in
            do {
                try await Task.sleep(until: time.advanced(by: holdDelay), clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.hardwarePress = HardwarePress(key: key, phase: .holding)
                try await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.clearHardwarePress()
            } catch { return }
        }
    }

    private func finishHardwarePress(_ code: InputCode, origin: RemoteInputOrigin?) {
        guard let down = hardwareDown, down.code == code, down.origin == origin,
              let press = hardwarePress else { return }
        let duration = down.time.duration(to: .now)
        hardwareTask?.cancel()
        hardwareDown = nil
        let holdDelay = press.key == "power" ? powerHoldDelay : dictation.holdDelay
        hardwarePress = HardwarePress(key: press.key, phase: duration >= holdDelay ? .longPress : .shortPress)
        hardwareTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.clearHardwarePress()
        }
    }

    private func clearHardwarePress() {
        hardwareTask?.cancel()
        hardwareTask = nil
        hardwareDown = nil
        hardwarePress = nil
    }

    private func flash(_ key: String) {
        pulseTask?.cancel()
        virtualPulse = key
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.virtualPulse = nil
        }
    }

    private func perform(_ action: AgentAction) {
        guard !isRunning else { return }
        error = nil
        if action == .mediaChooser || action == .appSwitcher {
            cancelPowerPress()
            if action == .mediaChooser { onShowMedia?() }
            else { onSwitchApps?() }
            return
        }
        isRunning = true
        feedback = nil
        let target = profile?.target
        Task {
            defer { isRunning = false }
            do {
                try await runAction(action, target)
                feedback = "已执行：\(action.title)"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func save(_ updated: Configuration? = nil) -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updated ?? config).write(to: storeURL, options: .atomic)
            if let updated { config = updated }
            storageError = nil
            return true
        } catch {
            storageError = "配置保存失败：\(error.localizedDescription)"
            return false
        }
    }
}

extension InputCode {
    // The RC003 sends its physical buttons on the keyboard page, including volume and return.
    private static let xiaomi2ProKeys = [
        0x66: "power", 0x3E: "voice", 0x52: "up", 0x50: "left", 0x28: "ok",
        0x4F: "right", 0x51: "down", 0xF1: "back", 0x80: "plus", 0x4A: "home",
        0x81: "minus", 0x65: "menu", 0x35: "tv"
    ]

    var xiaomi2ProSlot: String? {
        keyboardUsage.flatMap { Self.xiaomi2ProKeys[$0] }
    }

    private var keyboardUsage: Int? {
        guard collectionPage == 1, collectionUsage == 6, page == 7, value != 0 else { return nil }
        return usage == Int(UInt32.max) ? value : usage
    }

    private func isKeyboardUsage(_ key: Int) -> Bool {
        keyboardUsage == key
    }

    var isKeyboardF5: Bool {
        isKeyboardUsage(0x3E)
    }

    func matchesNavigationKey(_ slot: String) -> Bool {
        guard case let .foregroundKey(shortcut)? = AgentProfile.defaults.actions[slot] else { return false }
        return isNativeKeyboardShortcut(shortcut)
    }

    func isNativeKeyboardShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard shortcut.modifiers.isEmpty else { return false }
        let usages: [UInt16: Int] = [36: 0x28, 53: 0x29, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52]
        guard let usage = usages[shortcut.keyCode] else { return false }
        return isKeyboardUsage(usage)
    }

    func isNativeVolume(up: Bool) -> Bool {
        let control = up ? 0xE9 : 0xEA
        return collectionPage == 0x0C && collectionUsage == 1 && page == 0x0C
            && ((usage == control && value != 0) || (usage == Int(UInt32.max) && value == control))
    }
}

@MainActor
extension AgentAction {
    var title: String {
        switch self {
        case .openApp: "打开 ChatGPT"
        case .openLink: "打开网页"
        case .shortcut(AgentProfile.newChat): "新建对话"
        case .shortcut(AgentProfile.sendDraft): "发送当前草稿"
        case .shortcut(AgentProfile.stop): "停止生成"
        case .shortcut: "ChatGPT 快捷键"
        case .chatBar: "打开 ChatGPT Chat Bar"
        case .nextAgent: "切换到下一个 Agent"
        case .dictation: "Codex 听写"
        case .displaySleep: "关闭显示器"
        case .appleMenu: "打开苹果菜单"
        case .systemShortcut: "macOS 快捷键"
        case let .foregroundKey(keys): keys.label
        case .lockScreen: "锁定屏幕"
        case .showDesktop: "显示桌面"
        case .volumeUp: "提高音量"
        case .volumeDown: "降低音量"
        case .mediaChooser: "媒体应用选择器"
        case .appSwitcher: "切换应用"
        }
    }

    var detail: String? {
        switch self {
        case let .openLink(url): url
        case let .shortcut(keys): keys.label
        case .chatBar: "⌥Space"
        case let .systemShortcut(keys): keys.label
        default: nil
        }
    }
}

struct RemoteKey: Identifiable {
    let id: String
    let name: String
    let symbol: String

    static let xiaomi: [Self] = [
        .init(id: "power", name: "电源", symbol: "power"),
        .init(id: "voice", name: "语音", symbol: "mic"),
        .init(id: "up", name: "方向上", symbol: "chevron.up"),
        .init(id: "left", name: "方向左", symbol: "chevron.left"),
        .init(id: "ok", name: "确定", symbol: "circle.inset.filled"),
        .init(id: "right", name: "方向右", symbol: "chevron.right"),
        .init(id: "down", name: "方向下", symbol: "chevron.down"),
        .init(id: "back", name: "返回", symbol: "chevron.left"),
        .init(id: "plus", name: "音量加", symbol: "plus"),
        .init(id: "home", name: "主页", symbol: "house"),
        .init(id: "minus", name: "音量减", symbol: "minus"),
        .init(id: "menu", name: "菜单", symbol: "line.3.horizontal"),
        .init(id: "tv", name: "直播", symbol: "tv")
    ]
}
