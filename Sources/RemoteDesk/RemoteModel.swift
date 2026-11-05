import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import RemoteCore

struct PermissionAccess {
    var postEvents: () -> Bool
    var accessibility: () -> Bool
    var listenEvents: (() -> Bool)? = nil
    static var system: Self {
        Self(postEvents: CGPreflightPostEventAccess, accessibility: AXIsProcessTrusted,
             listenEvents: CGPreflightListenEventAccess)
    }
}

struct RemoteKeyRelease: Equatable {
    let id = UUID()
    let key: String
}

@MainActor @Observable
final class RemoteModel {
    struct Activity: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    struct HardwarePress {
        enum Phase: Equatable {
            case down, holding, shortPress, doublePress, longPress
        }

        let key: String
        let phase: Phase
    }

    struct CalibrationConflict {
        let input: InputCode
        let previous: String
        let target: String
    }

    private struct GesturePress {
        let input: InputCode
        let origin: RemoteInputOrigin?
        let started: ContinuousClock.Instant
        let secondTap: Bool
        var firedHold = false
        var holdTask: Task<Void, Never>?
    }

    private struct PendingTap {
        let input: InputCode
        let origin: RemoteInputOrigin?
        let deadline: ContinuousClock.Instant
        let task: Task<Void, Never>
    }

    private(set) var calibrationConflict: CalibrationConflict?
    private(set) var config = Configuration()
    private var discoveredDevices: [DeviceID] = []
    private var discoveredAmbiguities: Set<DeviceID> = []
    private(set) var devices: [DeviceID] = []
    private(set) var ambiguousDevices: Set<DeviceID> = []
    private(set) var monitorState: InputMonitorState = .permission
    private(set) var learning: String?
    private(set) var activity: [Activity] = []
    private(set) var feedback: String?
    private(set) var error: String?
    private(set) var storageError: String?
    private(set) var isRunning = false
    private(set) var canListen = false
    private(set) var canPost = false
    private(set) var canUseAccessibility = false
    var requestedPermission: PermissionKind?
    private(set) var hardwarePress: HardwarePress?
    private(set) var lastKeyRelease: RemoteKeyRelease?
    var pressedHardwareKey: String? { hardwareDown?.key }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                cancelLearning()
                cancelDictation()
                cancelGestures()
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
    private let permissionAccess: PermissionAccess
    private var catalog: RemoteCatalog
    var onModelChanged: (() -> Void)?
    private let runAction: @MainActor (AgentAction, AppTarget?) async throws -> Void
    private var draftActions: [String: AgentAction]?
    private var draftRemotes: [DeviceID: RemoteMap] = [:]
    private var canSave = true
    private var hardwareTask: Task<Void, Never>?
    private var hardwareDown: (key: String, code: InputCode, origin: RemoteInputOrigin?, time: ContinuousClock.Instant)?
    private var learningTask: Task<Void, Never>?
    private let powerHoldDelay: Duration
    private let doubleClickDelay: Duration
    private var gestures: [String: GesturePress] = [:]
    private var pendingTaps: [String: PendingTap] = [:]
    private struct AliasedPress {
        let input: InputCode
        let primary: RemoteInputOrigin
        var origins: Set<RemoteInputOrigin>
    }

    private var aliasedPresses: [String: AliasedPress] = [:]
    var onShowMedia: (() -> Void)?
    var onSwitchApps: (() -> Void)?
    var onMediaKey: ((String, Bool) -> Bool)?
    var onDismissMedia: (() -> Void)?

    convenience init() {
        let directory = ProcessInfo.processInfo.environment["INFINITE_REMOTE_DATA_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL.applicationSupportDirectory.appending(path: "RemoteDesk", directoryHint: .isDirectory)
        self.init(hid: HIDMonitor(), storeURL: directory.appending(path: "configuration.json"),
                  runAction: AgentRunner.run)
    }

    init(hid: any RemoteInputSource, storeURL: URL,
         dictation: DictationController = DictationController(),
         permissions: PermissionAccess = .system,
         powerHoldDelay: Duration = .milliseconds(600),
         doubleClickDelay: Duration = .milliseconds(300),
         runAction: @escaping @MainActor (AgentAction, AppTarget?) async throws -> Void) {
        self.dictation = dictation
        self.permissionAccess = permissions
        self.canListen = permissions.listenEvents?() ?? false
        self.canPost = permissions.postEvents()
        self.canUseAccessibility = permissions.accessibility()
        self.hid = hid
        self.storeURL = storeURL
        self.catalog = RemoteCatalog(directory: storeURL.deletingLastPathComponent()
            .appending(path: "RemoteModels", directoryHint: .isDirectory))
        self.runAction = runAction
        self.powerHoldDelay = powerHoldDelay
        self.doubleClickDelay = doubleClickDelay
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
                    storageError = L10n.tr("无法备份旧配置，本次更改不会覆盖原文件。")
                }
            } else {
                canSave = false
                storageError = L10n.tr("配置来自其他版本，本次更改不会覆盖原文件。")
            }
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // The initial configuration is saved after the first edit.
        } catch {
            canSave = false
            storageError = L10n.tr("无法读取配置，本次更改不会覆盖原文件。")
        }
        hid.selectedDevice = config.selectedDevice.flatMap { catalog.model(for: $0) == nil ? nil : $0 }
        resetSlot()
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

    var connectedDevice: DeviceID? {
        config.selectedDevice.flatMap { device in
            guard devices.contains(device), catalog.model(for: device)?.id == remoteDefinition.id else { return nil }
            return device
        }
    }
    var connected: Bool { connectedDevice != nil }
    var selectedAmbiguousDevices: Set<DeviceID> {
        Set(ambiguousDevices.filter { catalog.model(for: $0)?.id == remoteDefinition.id })
    }
    var libraryDirectory: URL { storeURL.deletingLastPathComponent().appending(path: "ResourceLibrary") }
    var resourceLoadIssues: [String] { catalog.loadIssues }
    var installedModels: [RemoteDefinition] { catalog.models }
    var hasRemote: Bool { !remoteDefinition.id.isEmpty }
    var remoteDefinition: RemoteDefinition {
        if let id = config.selectedModelID, let selected = installedModels.first(where: { $0.id == id }) { return selected }
        return config.selectedDevice.flatMap(catalog.model(for:)) ?? installedModels.first ?? .empty
    }
    var keys: [RemoteKey] { remoteDefinition.layout.keys }
    var consumesContextMenu: Bool { remoteDefinition.manifest.behavior.consumesContextMenu }
    func installedOwner(of id: String) -> String? { catalog.owner(of: id) }

    func installModel(from url: URL, sourceID: String? = nil) throws {
        guard !hasConfigurationChanges else {
            throw RemotePackageError.invalid(L10n.tr("请先保存或放弃当前配置更改。"))
        }
        let previousID = remoteDefinition.id
        let definition = try catalog.install(url, sourceID: sourceID)
        cancelLearning()
        cancelDictation()
        cancelGestures()
        clearHardwarePress()
        aliasedPresses.removeAll()
        onDismissMedia?()
        if previousID.isEmpty {
            config.selectedModelID = definition.id
            save()
        }
        updateAmbiguity(discoveredAmbiguities)
        updateDevices(discoveredDevices)
        if !connected { previewModel(definition.id) }
        resetSlot()
        onModelChanged?()
        error = nil
        feedback = L10n.format("已导入型号：%@", definition.manifest.name)
    }

    /// Keep ZIP decompression and integrity scans off the UI actor.
    func installResourcePackage(from url: URL, sourceID: String? = nil) async throws {
        let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if directory { try installModel(from: url, sourceID: sourceID); return }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "remote-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let folder = try await Task.detached(priority: .userInitiated) {
            try PackageArchive.extract(url, to: temporary)
        }.value
        try Task.checkCancellation()
        try installModel(from: folder, sourceID: sourceID)
    }

    /// Select an installed remote independently of its hardware connection.
    func previewModel(_ id: String) {
        guard !hasConfigurationChanges, installedModels.contains(where: { $0.id == id }) else { return }
        if remoteDefinition.id != id || config.selectedModelID == nil {
            var updated = config
            updated.selectedModelID = id
            guard save(updated) else { return }
            calibrationConflict = nil
            cancelLearning()
            cancelDictation()
            cancelGestures()
            clearHardwarePress()
            aliasedPresses.removeAll()
            onDismissMedia?()
        }
        let matching = selectableDevices.filter { catalog.model(for: $0)?.id == id }
        if matching.count == 1, let device = matching.first { selectDevice(device) }
        else {
            // Keep persisted hardware mapping, but never listen to another model.
            hid.selectedDevice = connectedDevice
        }
        // Config may already select this physical device after switching back
        // from an offline preview; reattach HID even when selectDevice is a no-op.
        hid.selectedDevice = connectedDevice
        resetSlot()
        onModelChanged?()
    }

    private func resetSlot() {
        slot = keys.contains { $0.id == "ok" } ? "ok" : (keys.first?.id ?? "")
    }
    var canReadKeys: Bool {
        canListen && connected && monitorState == .listening && !(connectedDevice.map(ambiguousDevices.contains) ?? false)
    }
    var selectableDevices: [DeviceID] { devices.filter { !ambiguousDevices.contains($0) } }
    private var defaultProfile: AgentProfile { defaultProfile(for: remoteDefinition.id) }

    private func defaultProfile(for modelID: String) -> AgentProfile {
        let definition = installedModels.first { $0.id == modelID } ?? .empty
        return AgentProfile(id: AgentProfile.defaults.id, name: L10n.tr("默认配置"),
                            target: definition.manifest.target, actions: definition.manifest.defaults, modelID: modelID)
    }

    var profile: AgentProfile? { hasRemote ? profile(for: remoteDefinition.id) : nil }
    var profiles: [AgentProfile] { hasRemote ? profiles(for: remoteDefinition.id) : [] }

    func profile(for modelID: String) -> AgentProfile {
        let id = config.activeAgentIDsByModel?[modelID]
        return profiles(for: modelID).first { $0.id == id } ?? defaultProfile(for: modelID)
    }

    private func profiles(for modelID: String) -> [AgentProfile] {
        [defaultProfile(for: modelID)] + config.agents.filter {
            $0.modelID == modelID && $0.id != AgentProfile.defaults.id
        }
    }

    private func selectProfileID(_ id: String, in updated: inout Configuration) {
        var selections = updated.activeAgentIDsByModel ?? [:]
        selections[remoteDefinition.id] = id
        updated.activeAgentIDsByModel = selections
        updated.activeAgentID = id // Preserve the legacy public configuration accessor.
    }
    var needsProfileName: Bool { profile?.id == AgentProfile.defaults.id && draftActions != nil }
    var editableActions: [String: AgentAction] { draftActions ?? profile?.actions ?? [:] }
    var editableRemote: RemoteMap? {
        guard let saved = config.activeRemote, catalog.model(for: saved.device)?.id == remoteDefinition.id else { return nil }
        return draftRemotes[saved.device] ?? saved
    }
    var hasConfigurationChanges: Bool { draftActions != nil || !draftRemotes.isEmpty || calibrationConflict != nil }
    var connectionStatus: String {
        guard connected else { return selectedAmbiguousDevices.isEmpty ? L10n.tr("未连接") : L10n.tr("已连接 · 设备无法区分") }
        if monitorState == .ambiguous || connectedDevice.map(ambiguousDevices.contains) == true { return L10n.tr("已连接 · 设备无法区分") }
        guard canReadKeys else { return L10n.tr("已连接 · 未监听") }
        if isDiagnosing { return L10n.tr("已连接 · 诊断中") }
        return isEnabled ? L10n.tr("已连接") : L10n.tr("已连接 · 已暂停")
    }

    func refreshPermissions() {
        updateMonitorState(hid.refresh())
        canPost = permissionAccess.postEvents()
        canUseAccessibility = permissionAccess.accessibility()
        if !canUseAccessibility { cancelDictation() }
    }

    private func updateMonitorState(_ state: InputMonitorState) {
        monitorState = state
        // Read authorization independently: ambiguity and permission can coexist.
        canListen = permissionAccess.listenEvents?() ?? (state != .permission)
        if !canReadKeys {
            aliasedPresses.removeAll()
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelGestures()
            onDismissMedia?()
        }
    }

    private func updateDevices(_ devices: [DeviceID]) {
        discoveredDevices = devices
        self.devices = devices.filter { catalog.model(for: $0) != nil }
        updateSelection()
    }

    private func updateAmbiguity(_ devices: Set<DeviceID>) {
        discoveredAmbiguities = devices
        ambiguousDevices = devices.filter { catalog.model(for: $0) != nil }
        if !canReadKeys {
            aliasedPresses.removeAll()
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelGestures()
            onDismissMedia?()
        }
    }

    private func updateSelection() {
        if (connectedDevice == nil || connectedDevice.map(ambiguousDevices.contains) == true),
           selectableDevices.filter({ catalog.model(for: $0)?.id == remoteDefinition.id }).count == 1,
           let device = selectableDevices.first(where: { catalog.model(for: $0)?.id == remoteDefinition.id }) {
            selectDevice(device)
        }
        if !canReadKeys {
            aliasedPresses.removeAll()
            cancelLearning()
            cancelDictation()
            clearHardwarePress()
            cancelGestures()
            onDismissMedia?()
        }
    }

    func requestListen() {
        if !CGRequestListenEventAccess() { openPrivacy("Privacy_ListenEvent") }
        refreshPermissions()
    }

    func requestPost() {
        let requested = CGRequestPostEventAccess()
        if !requested || !AXIsProcessTrusted() { openPrivacy("Privacy_Accessibility") }
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
        guard let definition = catalog.model(for: id), devices.contains(id), !ambiguousDevices.contains(id),
              config.selectedDevice != id || config.selectedModelID != definition.id,
              definition.id == remoteDefinition.id || !hasConfigurationChanges else { return }
        let previousModelID = remoteDefinition.id
        calibrationConflict = nil
        aliasedPresses.removeAll()
        cancelLearning()
        cancelDictation()
        clearHardwarePress()
        cancelGestures()
        onDismissMedia?()
        config.selectedModelID = definition.id
        config.selectDevice(id, layout: .generic)
        hid.selectedDevice = id
        resetSlot()
        if previousModelID != definition.id { onModelChanged?() }
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
        guard canReadKeys, isEnabled, !isDiagnosing, keys.contains(where: { $0.id == slot }) else { return }
        cancelLearning()
        cancelDictation()
        cancelGestures()
        onDismissMedia?()
        calibrationConflict = nil
        learning = slot
        feedback = nil
        error = nil
        learningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.cancelLearning()
            self?.error = L10n.tr("未收到按键。检查遥控器是否已连接，然后重试。")
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
        guard let saved = profile?.actions, remoteDefinition.actionSlots.contains(slot) else { return }
        cancelLearning()
        var actions = editableActions
        actions[slot] = action
        guard remoteDefinition.accepts(actions: actions) else { return }
        draftActions = actions == saved ? nil : actions
        feedback = nil
        error = nil
    }

    func restoreDefaultActions() {
        cancelLearning()
        let defaults = defaultProfile.actions
        draftActions = profile?.actions == defaults ? nil : defaults
        feedback = draftActions == nil ? L10n.tr("当前已使用默认按键。") : L10n.tr("已载入默认按键，保存后生效。")
        error = nil
    }

    @discardableResult
    func saveConfigurationChanges(as name: String? = nil) -> Bool {
        guard hasConfigurationChanges, learning == nil, calibrationConflict == nil,
              remoteDefinition.accepts(actions: editableActions) else { return false }
        var updated = config
        if let draftActions {
            if needsProfileName {
                guard let name = availableProfileName(name) else { return false }
                let copy = AgentProfile(name: name, target: defaultProfile.target, actions: draftActions,
                                        modelID: remoteDefinition.id)
                updated.agents.append(copy)
                selectProfileID(copy.id, in: &updated)
            } else if let index = updated.agents.firstIndex(where: { $0.id == profile?.id }) {
                updated.agents[index].actions = draftActions
            }
        }
        updated.remotes = updated.remotes.map { draftRemotes[$0.device] ?? $0 }
        guard save(updated) else { return false }
        cancelGestures()
        cancelDictation()
        onDismissMedia?()
        draftActions = nil
        draftRemotes = [:]
        error = nil
        feedback = L10n.tr("配置已保存")
        return true
    }

    @discardableResult
    func selectProfile(_ id: String, discardingDraft: Bool = false) -> Bool {
        guard profiles.contains(where: { $0.id == id }), profile?.id != id,
              discardingDraft || !hasConfigurationChanges else { return false }
        var updated = config
        selectProfileID(id, in: &updated)
        guard save(updated) else { return false }
        discardConfigurationChanges()
        cancelGestures()
        cancelDictation()
        onDismissMedia?()
        return true
    }

    @discardableResult
    func importProfile(_ archive: ProfileArchive, as name: String, discardingDraft: Bool) -> Bool {
        guard discardingDraft || !hasConfigurationChanges, let name = availableProfileName(name) else { return false }
        guard archive.associatedModelID == remoteDefinition.id,
              remoteDefinition.accepts(actions: archive.actions) else {
            error = L10n.tr("此配置与当前遥控器型号不匹配。")
            return false
        }
        let copy = AgentProfile(name: name, target: defaultProfile.target, actions: archive.actions,
                                modelID: remoteDefinition.id)
        var updated = config
        updated.agents.append(copy)
        selectProfileID(copy.id, in: &updated)
        guard save(updated) else { return false }
        discardConfigurationChanges()
        cancelGestures()
        cancelDictation()
        onDismissMedia?()
        feedback = L10n.tr("配置已导入")
        return true
    }

    private func availableProfileName(_ proposed: String?) -> String? {
        let name = proposed?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
        guard !name.isEmpty else {
            error = L10n.tr("请输入配置名称。")
            return nil
        }
        guard !profiles.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased() == name.lowercased() }) else {
            error = L10n.tr("此配置名称已存在。")
            return nil
        }
        return name
    }

    func discardConfigurationChanges() {
        cancelLearning()
        calibrationConflict = nil
        draftActions = nil
        draftRemotes = [:]
        feedback = nil
        error = nil
    }

    func setDiagnosing(_ active: Bool) {
        if active {
            cancelLearning()
            cancelDictation()
            cancelGestures()
            onDismissMedia?()
        }
        isDiagnosing = active
    }

    func pressVirtualKey(_ id: String) {
        guard !isDiagnosing, learning == nil, calibrationConflict == nil, !isRunning, !dictation.phase.active,
              keys.contains(where: { $0.id == id }) else { return }
        lastKeyRelease = RemoteKeyRelease(key: id)
        feedback = nil
        error = nil
        guard canReadKeys else {
            if !canListen { requestedPermission = .inputMonitoring }
            return
        }
        guard isEnabled else {
            feedback = L10n.tr("遥控触发已暂停")
            return
        }
        if onMediaKey?(id, false) == true { return }
        guard let action = profile?.actions[id] else {
            feedback = L10n.tr("此键尚未分配动作")
            return
        }
        if action == .dictation {
            feedback = L10n.tr("请按住实体语音键开始听写。")
        } else {
            perform(action)
        }
    }

    private func receive(_ device: DeviceID, _ event: RemoteInputEvent) {
        guard config.selectedDevice == device, canReadKeys else { return }
        switch event {
        case let .pressed(input, origin):
            receivePress(input, slot: learnedSlot(for: input, in: config.activeRemote) ?? remoteDefinition.slot(for: input),
                         origin: origin)
        case let .released(input, origin):
            let slot = learnedSlot(for: input, in: config.activeRemote) ?? remoteDefinition.slot(for: input)
            let name = slot.flatMap { id in keys.first { $0.id == id }?.name }
            record(L10n.format("松开 · %@%@", String(describing: name.map { $0 + " · " } ?? ""), String(describing: input.label)))
            if let key = aliasedKey(for: input), let origin, var press = aliasedPresses[key] {
                guard press.origins.remove(origin) != nil else { return }
                if press.origins.isEmpty {
                    aliasedPresses[key] = nil
                    releaseInput(press.input, origin: press.primary)
                } else {
                    aliasedPresses[key] = press
                }
            } else {
                releaseInput(input, origin: origin)
            }
        case let .replaced(input, origin):
            let key = aliasedKey(for: input)
            let interruptedKey = key.flatMap { key in
                aliasedPresses[key]?.origins.contains(origin) == true ? key : nil
            }
            if let interruptedKey { aliasedPresses[interruptedKey] = nil }
            interruptInput { code, source in
                (code == input && source == origin)
                    || interruptedKey.map { self.aliasedKey(for: code) == $0 } == true
            }
        case let .endpointClosed(endpoint):
            let interruptedKeys = Set(aliasedPresses.filter {
                $0.value.origins.contains { $0.endpoint == endpoint }
            }.keys)
            for key in interruptedKeys { aliasedPresses[key] = nil }
            interruptInput { code, source in
                source?.endpoint == endpoint
                    || self.aliasedKey(for: code).map(interruptedKeys.contains) == true
            }
        }
    }

    private func releaseInput(_ input: InputCode, origin: RemoteInputOrigin?) {
        finishHardwarePress(input, origin: origin)
        finishGesture(input, origin: origin)
        if let held = dictationInput, held.code == input, held.origin == origin {
            dictation.release()
            if !dictation.phase.active { dictationInput = nil }
        }
    }

    private func interruptInput(_ matches: (InputCode, RemoteInputOrigin?) -> Bool) {
        for (id, press) in gestures.filter({ matches($0.value.input, $0.value.origin) }) {
            press.holdTask?.cancel()
            gestures[id] = nil
        }
        for (id, tap) in pendingTaps.filter({ matches($0.value.input, $0.value.origin) }) {
            tap.task.cancel()
            pendingTaps[id] = nil
        }
        if let down = hardwareDown, matches(down.code, down.origin) { clearHardwarePress() }
        if let held = dictationInput, matches(held.code, held.origin) { cancelDictation() }
    }

    private func aliasedKey(for input: InputCode) -> String? {
        guard let key = remoteDefinition.slot(for: input),
              remoteDefinition.manifest.behavior.coalescedKeys.contains(key) else { return nil }
        return key
    }

    private func learnedSlot(for input: InputCode, in remote: RemoteMap?) -> String? {
        if let key = aliasedKey(for: input) {
            // Existing calibrations may have captured either report.
            return remote?.keys.last { aliasedKey(for: $0.input) == key }?.slot
        }
        return remote?.slot(for: input)
    }

    private func receivePress(_ input: InputCode, slot knownSlot: String?, origin: RemoteInputOrigin?) {
        let visibleSlot = knownSlot.flatMap { candidate in keys.first { $0.id == candidate } }
        record(L10n.format("按下 · %@%@", String(describing: visibleSlot.map { $0.name + " · " } ?? ""), String(describing: input.label)))

        // The RC003 can send both a keyboard array report and a discrete report for one press.
        if let key = aliasedKey(for: input), let origin {
            if aliasedPresses[key] != nil {
                aliasedPresses[key]?.origins.insert(origin)
                return
            }
            aliasedPresses[key] = AliasedPress(input: input, primary: origin, origins: [origin])
        }

        if let key = learning {
            cancelLearning()
            let previous = learnedSlot(for: input, in: editableRemote) ?? remoteDefinition.slot(for: input)
            if let previous, previous != key {
                calibrationConflict = CalibrationConflict(input: input, previous: previous, target: key)
            } else {
                applyCalibration(input, to: key)
            }
            showHardwarePress(key, code: input, origin: origin)
            return
        }
        guard calibrationConflict == nil, let visibleSlot else { return }
        showHardwarePress(visibleSlot.id, code: input, origin: origin)
        guard isEnabled, !isDiagnosing, !isRunning, !dictation.phase.active else { return }
        if onMediaKey?(visibleSlot.id, profile?.actions[visibleSlot.id].map { action in
            if case let .foregroundKey(shortcut) = action { return input.isNativeKeyboardShortcut(shortcut) }
            return false
        } ?? false) == true {
            cancelGestures()
            return
        }
        let action = profile?.actions[visibleSlot.id]
        if action != .dictation && (remoteDefinition.manifest.behavior.deferredKeys.contains(visibleSlot.id)
            || gestureAction(visibleSlot.holdSlot, for: visibleSlot) != nil
            || gestureAction(visibleSlot.doubleSlot, for: visibleSlot) != nil) {
            startGesture(visibleSlot, input: input, origin: origin)
            return
        }
        guard let action else { return }
        if action == .dictation {
            feedback = nil
            error = nil
            // Packages can declare native keyboard dictation pass-through.
            // Preserve both native edges instead of dispatching a duplicate action.
            if remoteDefinition.manifest.behavior.nativeDictationKeys.contains(visibleSlot.id) && input.isKeyboardF5 { return }
            guard canUseAccessibility else { requestedPermission = .accessibility; return }
            dictationInput = (input, origin)
            dictation.press()
        } else {
            dispatch(action, input: input, nativeSingle: true)
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
        dictation.cancel(L10n.tr("听写已取消，未发送。"))
    }

    func resolveCalibrationConflict(transfer: Bool) {
        guard let conflict = calibrationConflict else { return }
        calibrationConflict = nil
        if transfer { applyCalibration(conflict.input, to: conflict.target) }
    }

    private func applyCalibration(_ input: InputCode, to key: String) {
        updateRemoteDraft {
            if let alias = aliasedKey(for: input) { $0.keys.removeAll { aliasedKey(for: $0.input) == alias } }
            $0.learn(input, as: key)
        }
        let name = keys.first { $0.id == key }?.name ?? key
        feedback = L10n.format("已收到「%@」的按键信号，保存后生效。", String(describing: name))
    }

    private func gestureAction(_ slot: String, for key: RemoteKey) -> AgentAction? {
        guard key.actionSlots.contains(slot), let action = profile?.actions[slot], action != .dictation else { return nil }
        return action
    }

    private func startGesture(_ key: RemoteKey, input: InputCode, origin: RemoteInputOrigin?) {
        guard gestures[key.id] == nil else { return }
        let now = ContinuousClock.now
        let pending = pendingTaps.removeValue(forKey: key.id)
        pending?.task.cancel()
        let secondTap = pending.map { now < $0.deadline } ?? false
        if let pending, !secondTap { runGesture(key.id, for: key, input: pending.input) }

        var press = GesturePress(input: input, origin: origin, started: now, secondTap: secondTap)
        if gestureAction(key.holdSlot, for: key) != nil {
            press.holdTask = Task { [weak self, powerHoldDelay] in
                do { try await Task.sleep(until: now.advanced(by: powerHoldDelay), clock: .continuous) }
                catch { return }
                self?.fireHold(key)
            }
        }
        gestures[key.id] = press
    }

    private func fireHold(_ key: RemoteKey) {
        guard var press = gestures[key.id], !press.firedHold else { return }
        press.firedHold = true
        gestures[key.id] = press
        runGesture(key.holdSlot, for: key, input: press.input)
    }

    private func finishGesture(_ input: InputCode, origin: RemoteInputOrigin?) {
        guard let id = gestures.first(where: { $0.value.input == input && $0.value.origin == origin })?.key,
              let press = gestures.removeValue(forKey: id), let key = keys.first(where: { $0.id == id }) else { return }
        press.holdTask?.cancel()
        guard !press.firedHold else { return }
        let now = ContinuousClock.now
        let recognizesHold = gestureAction(key.holdSlot, for: key) != nil || gestureAction(key.doubleSlot, for: key) != nil
        if recognizesHold && press.started.duration(to: now) >= powerHoldDelay {
            runGesture(key.holdSlot, for: key, input: input)
        } else if press.secondTap {
            if hardwareDown == nil, hardwarePress?.key == key.id {
                hardwareTask?.cancel()
                hardwarePress = HardwarePress(key: key.id, phase: .doublePress)
                scheduleHardwareClear()
            }
            runGesture(key.doubleSlot, for: key, input: input)
        } else if gestureAction(key.doubleSlot, for: key) != nil {
            let deadline = now.advanced(by: doubleClickDelay)
            let task = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let self, self.pendingTaps.removeValue(forKey: key.id) != nil else { return }
                self.runGesture(key.id, for: key, input: input)
            }
            pendingTaps[key.id] = PendingTap(input: input, origin: origin, deadline: deadline, task: task)
        } else {
            runGesture(key.id, for: key, input: input)
        }
    }

    private func runGesture(_ slot: String, for key: RemoteKey, input: InputCode) {
        guard isEnabled, canReadKeys, !isDiagnosing, learning == nil, calibrationConflict == nil,
              !dictation.phase.active, let action = gestureAction(slot, for: key) else { return }
        dispatch(action, input: input, nativeSingle: slot == key.id)
    }

    private func dispatch(_ action: AgentAction, input: InputCode, nativeSingle: Bool) {
        if nativeSingle {
            switch action {
            case let .foregroundKey(shortcut) where input.isNativeKeyboardShortcut(shortcut): return
            case .volumeUp where input.isNativeVolume(up: true): return
            case .volumeDown where input.isNativeVolume(up: false): return
            default: break
            }
        }
        perform(action)
    }

    func cancelGestures() {
        for press in gestures.values { press.holdTask?.cancel() }
        for tap in pendingTaps.values { tap.task.cancel() }
        gestures.removeAll()
        pendingTaps.removeAll()
    }

    private func showHardwarePress(_ key: String, code: InputCode, origin: RemoteInputOrigin?) {
        if let down = hardwareDown, down.code == code, down.origin == origin { return }
        hardwareTask?.cancel()
        let time = ContinuousClock.now
        let holdDelay = keys.contains { $0.id == key && $0.longPress == true } ? powerHoldDelay : dictation.holdDelay
        hardwareDown = (key, code, origin, time)
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
        guard let down = hardwareDown, down.code == code, down.origin == origin else { return }
        let duration = down.time.duration(to: .now)
        hardwareTask?.cancel()
        hardwareDown = nil
        lastKeyRelease = RemoteKeyRelease(key: down.key)
        let holdDelay = keys.contains { $0.id == down.key && $0.longPress == true } ? powerHoldDelay : dictation.holdDelay
        hardwarePress = HardwarePress(key: down.key, phase: duration >= holdDelay ? .longPress : .shortPress)
        scheduleHardwareClear()
    }

    private func scheduleHardwareClear() {
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

    private func perform(_ action: AgentAction) {
        guard !isRunning else { return }
        switch action {
        case .shortcut, .foregroundKey, .systemShortcut:
            guard canPost else { requestedPermission = .accessibility; return }
        case .appleMenu, .dictation:
            guard canUseAccessibility else { requestedPermission = .accessibility; return }
        default: break
        }
        error = nil
        if action == .mediaChooser || action == .appSwitcher {
            cancelGestures()
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
                feedback = L10n.format("已执行：%@", String(describing: action.title))
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
            storageError = L10n.format("配置保存失败：%@", String(describing: error.localizedDescription))
            return false
        }
    }
}

extension InputCode {
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
        case .openApp: L10n.tr("打开 ChatGPT")
        case .openLink: L10n.tr("打开网页")
        case .shortcut(AgentProfile.newChat): L10n.tr("新建对话")
        case .shortcut(AgentProfile.sendDraft): L10n.tr("发送当前草稿")
        case .shortcut(AgentProfile.stop): L10n.tr("停止生成")
        case .shortcut: L10n.tr("ChatGPT 快捷键")
        case .chatBar: L10n.tr("打开 ChatGPT Chat Bar")
        case .nextAgent: L10n.tr("切换到下一个 Agent")
        case .dictation: L10n.tr("Codex 听写")
        case .displaySleep: L10n.tr("显示器休眠")
        case .toggleDisplays: L10n.tr("关闭或恢复显示器")
        case .appleMenu: L10n.tr("打开苹果菜单")
        case .systemShortcut: L10n.tr("macOS 快捷键")
        case let .foregroundKey(keys): keys.label
        case .lockScreen: L10n.tr("锁定屏幕")
        case .showDesktop: L10n.tr("显示桌面")
        case .volumeUp: L10n.tr("提高音量")
        case .volumeDown: L10n.tr("降低音量")
        case .mediaChooser: L10n.tr("媒体应用选择器")
        case .appSwitcher: L10n.tr("切换应用")
        }
    }

    var detail: String? {
        switch self {
        case let .openLink(url): url
        case let .shortcut(keys): keys.label
        case .chatBar: "⌥Space"
        case let .systemShortcut(keys): keys.label
        case .toggleDisplays: L10n.tr("短按关闭支持的外接屏并调低内置屏亮度，再按恢复")
        case .displaySleep: L10n.tr("唤醒时是否需要密码取决于 macOS 的「锁定屏幕」设置")
        default: nil
        }
    }
}
