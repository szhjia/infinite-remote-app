import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import IOKit.hid
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

enum RemoteReadiness: Equatable {
    case noModel, unpaired, chooseDevice, ambiguous, needsInputMonitoring, monitorUnavailable
    case listening, paused, diagnosing, calibrating

    var title: String {
        switch self {
        case .noModel: L10n.tr("尚未添加遥控器")
        case .unpaired: L10n.tr("未连接")
        case .chooseDevice: L10n.tr("请选择已配对的遥控器")
        case .ambiguous: L10n.tr("已连接 · 设备无法区分")
        case .needsInputMonitoring: L10n.tr("已连接 · 缺少输入监控")
        case .monitorUnavailable: L10n.tr("已连接 · 监听未启动")
        case .listening: L10n.tr("已连接 · 正在监听")
        case .paused: L10n.tr("已暂停响应 · 仍可测试按键")
        case .diagnosing: L10n.tr("诊断中 · 动作暂停")
        case .calibrating: L10n.tr("校准中 · 动作暂停")
        }
    }
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
        let context: ForegroundContext?
        var firedHold = false
        var holdTask: Task<Void, Never>?
    }

    private struct PendingTap {
        let input: InputCode
        let origin: RemoteInputOrigin?
        let deadline: ContinuousClock.Instant
        let context: ForegroundContext?
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
    private(set) var capturesKeyboard = false
    private(set) var usesRemoteMicrophone = false
    let remoteMicrophone = RemoteMicrophone()
    private(set) var activeBundleID: String?
    private var contextGeneration = 0
    private var editingBundleID: String?
    var shortcutsNeedRestart: Bool { canUseAccessibility && !canPost }
    var requestedPermission: PermissionKind?
    private(set) var hardwarePress: HardwarePress?
    private(set) var lastKeyRelease: RemoteKeyRelease?
    private var diagnosticSignal: (device: DeviceID, key: String)?
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
            updateCapture()
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
    private let foreground: @MainActor () -> ForegroundContext?
    private let isChatGPTEnabled: Bool
    private let finderSupportsNavigation: @MainActor (ForegroundContext) -> Bool
    private let postVoice: @MainActor (KeyboardShortcut, Bool) throws -> Void
    private var heldVoice: (input: InputCode, origin: RemoteInputOrigin?, shortcut: KeyboardShortcut)?
    private var microphonePress: (input: InputCode, origin: RemoteInputOrigin?, context: ForegroundContext)?
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
        self.init(hid: HIDMonitor(recoveryURL: directory.appending(path: "keyboard-capture.json")),
                  storeURL: directory.appending(path: "configuration.json"),
                  foreground: ForegroundContext.current, finderSupportsNavigation: AgentRunner.finder.supports,
                  postVoice: AgentRunner.postVoiceEdge, runAction: AgentRunner.run)
    }

    init(hid: any RemoteInputSource, storeURL: URL,
         dictation: DictationController = DictationController(),
         permissions: PermissionAccess = .system,
         powerHoldDelay: Duration = .milliseconds(600),
         doubleClickDelay: Duration = .milliseconds(300),
         foreground: @escaping @MainActor () -> ForegroundContext? = ForegroundContext.current,
         isChatGPTEnabled: Bool = AgentRunner.isChatGPTEnabled,
         finderSupportsNavigation: @escaping @MainActor (ForegroundContext) -> Bool = { _ in true },
         postVoice: @escaping @MainActor (KeyboardShortcut, Bool) throws -> Void = AgentRunner.postVoiceEdge,
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
        self.foreground = foreground
        self.isChatGPTEnabled = isChatGPTEnabled
        self.finderSupportsNavigation = finderSupportsNavigation
        self.postVoice = postVoice
        self.activeBundleID = foreground()?.bundleID
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
        hid.onKeyboardCapture = { [weak self] capture in self?.capturesKeyboard = capture }
        remoteMicrophone.canStream = { [weak self] in
            guard let self, usesRemoteMicrophone, let press = microphonePress else { return false }
            return press.context.matches(foreground())
        }
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
    var hasVoiceKey: Bool { remoteDefinition.actionSlots.contains("voice") }
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
    var devicesForSelectedModel: [DeviceID] {
        selectableDevices.filter { catalog.model(for: $0)?.id == remoteDefinition.id }
    }
    private var defaultProfile: AgentProfile { defaultProfile(for: remoteDefinition, target: editingApp) }

    var apps: [AppTarget] { apps(for: remoteDefinition) }

    private func apps(for definition: RemoteDefinition) -> [AppTarget] {
        let modelID = definition.id
        let saved = config.addedAppsByModel?[modelID] ?? []
        let legacy = config.agents.filter { $0.modelID == modelID }.compactMap(\.target)
        var ids: Set<String> = []
        return ([.finder, .chatGPT] + saved + [definition.manifest.target].compactMap { $0 } + legacy)
            .filter { ids.insert($0.bundleID).inserted }
    }

    var editingApp: AppTarget {
        apps.first { $0.bundleID == editingBundleID } ?? .finder
    }

    var unassignedProfiles: [AgentProfile] {
        config.agents.filter { $0.modelID == remoteDefinition.id && $0.target == nil }
    }

    func selectEditingApp(_ app: AppTarget, discardingDraft: Bool = false) {
        guard apps.contains(where: { $0.bundleID == app.bundleID }),
              app.bundleID != editingApp.bundleID, discardingDraft || !hasConfigurationChanges else { return }
        discardConfigurationChanges()
        editingBundleID = app.bundleID
    }

    @discardableResult
    func addApp(_ app: AppTarget, discardingDraft: Bool = false) -> Bool {
        guard discardingDraft || !hasConfigurationChanges else { return false }
        if !apps.contains(where: { $0.bundleID == app.bundleID }) {
            var updated = config
            var saved = updated.addedAppsByModel ?? [:]
            saved[remoteDefinition.id, default: []].append(app)
            updated.addedAppsByModel = saved
            guard save(updated) else { return false }
        }
        selectEditingApp(app, discardingDraft: discardingDraft)
        return true
    }

    @discardableResult
    func assignProfile(_ id: String) -> Bool {
        guard !hasConfigurationChanges, unassignedProfiles.contains(where: { $0.id == id }),
              let index = config.agents.firstIndex(where: { $0.id == id }) else { return false }
        var updated = config
        updated.agents[index].target = editingApp
        selectProfileID(id, in: &updated)
        guard save(updated) else { return false }
        cancelGestures()
        cancelDictation()
        return true
    }

    private func defaultProfile(for definition: RemoteDefinition, target: AppTarget) -> AgentProfile {
        var actions = definition.manifest.defaults.filter { _, action in
            switch action {
            case .shortcut, .openApp: target.bundleID == definition.manifest.target?.bundleID
            case .dictation, .chatBar, .nextAgent: false
            default: true
            }
        }
        if target.bundleID == AppTarget.finder.bundleID {
            let navigation: [String: FinderCommand] = [
                "up": .up, "up-double": .pageUp, "up-long": .up,
                "down": .down, "down-double": .pageDown, "down-long": .down,
                "left": .left, "left-double": .sidebar, "left-long": .left,
                "right": .right, "right-double": .content, "right-long": .right,
                "ok": .open, "ok-double": .contextMenu, "back": .escape
            ]
            for (slot, command) in navigation where definition.actionSlots.contains(slot) {
                actions[slot] = .finder(command)
            }
        } else if target.bundleID == AppTarget.chatGPT.bundleID, definition.actionSlots.contains("voice"),
                  config.defaultVoiceByModel?[definition.id] == nil {
            actions["voice"] = .chatGPTDraft
        }
        for slot in definition.actionSlots {
            if let action = globalAction(slot, definition: definition) { actions[slot] = action }
        }
        return AgentProfile(id: AgentProfile.defaults.id, name: L10n.tr("默认配置"),
                            target: target, actions: actions, modelID: definition.id)
    }

    var profile: AgentProfile? { hasRemote ? profile(for: remoteDefinition.id) : nil }
    var profiles: [AgentProfile] { hasRemote ? profiles(for: remoteDefinition, app: editingApp) : [] }

    func profile(for modelID: String) -> AgentProfile {
        let definition = installedModels.first { $0.id == modelID } ?? .empty
        let app = apps(for: definition).first { $0.bundleID == editingBundleID } ?? .finder
        return profile(for: definition, app: app)
    }

    private func profile(for definition: RemoteDefinition, app: AppTarget) -> AgentProfile {
        let id = config.activeProfileID(modelID: definition.id, bundleID: app.bundleID)
        return profiles(for: definition, app: app).first { $0.id == id } ?? defaultProfile(for: definition, target: app)
    }

    private func profiles(for definition: RemoteDefinition, app: AppTarget) -> [AgentProfile] {
        [defaultProfile(for: definition, target: app)] + config.agents.filter {
            $0.modelID == definition.id && $0.target?.bundleID == app.bundleID && $0.id != AgentProfile.defaults.id
        }
    }

    private func selectProfileID(_ id: String, in updated: inout Configuration, target: AppTarget? = nil) {
        updated.selectProfile(id, modelID: remoteDefinition.id, bundleID: (target ?? editingApp).bundleID)
    }

    func isGlobalSlot(_ slot: String) -> Bool {
        let key: String
        if slot.hasSuffix("-double") { key = String(slot.dropLast("-double".count)) }
        else if slot.hasSuffix("-long") { key = String(slot.dropLast("-long".count)) }
        else { key = slot }
        return globalAction(key, definition: remoteDefinition) != nil
    }

    private func globalAction(_ slot: String, definition: RemoteDefinition) -> AgentAction? {
        guard definition.actionSlots.contains(slot) else { return nil }
        switch slot {
        case "home": return .openFinder
        case "menu" where definition.manifest.defaults[slot] == .appSwitcher: return .appSwitcher
        case "tv" where definition.manifest.defaults[slot] == .mediaChooser: return .mediaChooser
        default: return nil
        }
    }

    var defaultVoice: AgentAction? { config.defaultVoiceByModel?[remoteDefinition.id] }

    @discardableResult
    func setDefaultVoice(_ action: AgentAction?) -> Bool {
        if let action {
            guard case let .voiceShortcut(.macOS, shortcut) = action, shortcut.isVoiceCombination else { return false }
        }
        var updated = config
        var voices = updated.defaultVoiceByModel ?? [:]
        voices[remoteDefinition.id] = action
        updated.defaultVoiceByModel = voices
        guard save(updated) else { return false }
        cancelDictation()
        return true
    }

    private func runtimeAction(_ slot: String, context: ForegroundContext?) -> AgentAction? {
        if let global = globalAction(slot, definition: remoteDefinition) { return global }
        if let app = apps.first(where: { $0.bundleID == context?.bundleID }),
           isChatGPTEnabled || app.bundleID != AppTarget.chatGPT.bundleID {
            let configured = profile(for: remoteDefinition, app: app).actions
            if let action = configured[slot] { return action }
            if slot == "voice" { return defaultVoice }
            return nil
        }
        if slot == "voice" { return defaultVoice }
        switch remoteDefinition.manifest.defaults[slot] {
        case .shortcut, .dictation, .openApp, .chatBar, .nextAgent: return nil
        default: return remoteDefinition.manifest.defaults[slot]
        }
    }
    var needsProfileName: Bool { profile?.id == AgentProfile.defaults.id && draftActions != nil }
    var editableActions: [String: AgentAction] {
        var actions = draftActions ?? profile?.actions ?? [:]
        for slot in ["home", "menu", "tv"] {
            if let action = globalAction(slot, definition: remoteDefinition) { actions[slot] = action }
        }
        return actions
    }
    var editableRemote: RemoteMap? {
        guard let saved = config.activeRemote, catalog.model(for: saved.device)?.id == remoteDefinition.id else { return nil }
        return draftRemotes[saved.device] ?? saved
    }
    var hasConfigurationChanges: Bool { draftActions != nil || !draftRemotes.isEmpty || calibrationConflict != nil }
    var readiness: RemoteReadiness {
        guard hasRemote else { return .noModel }
        if monitorState == .ambiguous || (connectedDevice.map(ambiguousDevices.contains) ?? !selectedAmbiguousDevices.isEmpty) {
            return .ambiguous
        }
        guard connected else { return devicesForSelectedModel.isEmpty ? .unpaired : .chooseDevice }
        guard canListen else { return .needsInputMonitoring }
        guard canReadKeys else { return .monitorUnavailable }
        if isDiagnosing { return .diagnosing }
        if learning != nil { return .calibrating }
        return isEnabled ? .listening : .paused
    }

    var connectionStatus: String { readiness.title }

    var hasVerifiedInput: Bool {
        guard let device = connectedDevice else { return false }
        return config.verifiedRemoteDevices?.contains(device) == true || diagnosticSignal?.device == device
    }

    var diagnosticKeyName: String? {
        guard canReadKeys, let signal = diagnosticSignal, signal.device == connectedDevice else { return nil }
        return keys.first { $0.id == signal.key }?.name
    }

    func refreshPermissions() {
        updateMonitorState(hid.refresh())
        canPost = permissionAccess.postEvents()
        canUseAccessibility = permissionAccess.accessibility()
        if !canUseAccessibility { cancelDictation() }
        updateCapture()
    }

    private func updateCapture() {
        let context = foreground()
        hid.preservesNativeF5 = context?.bundleID == AppTarget.chatGPT.bundleID
            && remoteDefinition.manifest.behavior.nativeDictationKeys.contains { key in
                guard config.activeRemote?.keys.contains(where: { $0.input.isKeyboardF5 && $0.slot != key }) != true
                else { return false }
                let action = runtimeAction(key, context: context)
                return action == .chatGPTDraft || action == .dictation
            }
        hid.wantsExclusiveKeyboard = isEnabled && !isDiagnosing && canPost && canUseAccessibility
        updateMicrophoneConnection()
    }

    var supportsRemoteMicrophone: Bool {
        connectedDevice?.vendor == 0x2717 && connectedDevice?.product == 0x32B8
    }

    func toggleRemoteMicrophone() {
        usesRemoteMicrophone.toggle()
        if !usesRemoteMicrophone { microphonePress = nil }
        updateMicrophoneConnection()
    }

    private func updateMicrophoneConnection() {
        let enabled = usesRemoteMicrophone && supportsRemoteMicrophone && isEnabled && !isDiagnosing && canReadKeys
        remoteMicrophone.connect(enabled ? hid.selectedBluetoothIdentifier : nil, enabled: enabled)
    }

    func foregroundChanged() {
        contextGeneration &+= 1
        activeBundleID = foreground()?.bundleID
        cancelGestures()
        cancelDictation()
        updateCapture()
    }

    func stopResponding() {
        isEnabled = false
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
        updateMicrophoneConnection()
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
        updateMicrophoneConnection()
    }

    func requestListen() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { openPrivacy("Privacy_ListenEvent") }
        refreshPermissions()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) { openPrivacy("Privacy_Accessibility") }
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

    func requestVoiceBluetooth() {
        if !remoteMicrophone.requestBluetoothAuthorization() { openPrivacy("Privacy_Bluetooth") }
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
        guard profile != nil, !isGlobalSlot(slot), remoteDefinition.actionSlots.contains(slot) else { return }
        cancelLearning()
        var actions = editableActions
        actions[slot] = action
        guard remoteDefinition.accepts(actions: actions) else { return }
        var saved = profile?.actions ?? [:]
        for key in ["home", "menu", "tv"] where isGlobalSlot(key) { saved[key] = editableActions[key] }
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
                var saved = draftActions
                for slot in ["home", "menu", "tv"] where isGlobalSlot(slot) {
                    saved[slot] = updated.agents[index].actions[slot]
                }
                updated.agents[index].actions = saved
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
        let target = importTarget(for: archive)
        guard discardingDraft || !hasConfigurationChanges,
              let name = availableProfileName(name, for: target) else { return false }
        guard archive.associatedModelID == remoteDefinition.id,
              remoteDefinition.accepts(actions: archive.actions) else {
            error = L10n.tr("此配置与当前遥控器型号不匹配。")
            return false
        }
        let copy = AgentProfile(name: name, target: target, actions: archive.actions,
                                modelID: remoteDefinition.id)
        var updated = config
        updated.agents.append(copy)
        selectProfileID(copy.id, in: &updated, target: target)
        guard save(updated) else { return false }
        discardConfigurationChanges()
        editingBundleID = target.bundleID
        cancelGestures()
        cancelDictation()
        onDismissMedia?()
        feedback = L10n.tr("配置已导入")
        return true
    }

    func importTarget(for archive: ProfileArchive) -> AppTarget {
        archive.target ?? remoteDefinition.manifest.target ?? editingApp
    }

    private func availableProfileName(_ proposed: String?, for target: AppTarget? = nil) -> String? {
        let name = proposed?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
        guard !name.isEmpty else {
            error = L10n.tr("请输入配置名称。")
            return nil
        }
        guard !profiles(for: remoteDefinition, app: target ?? editingApp).contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if active && !isDiagnosing {
            diagnosticSignal = nil
            aliasedPresses.removeAll()
            clearHardwarePress()
            cancelLearning()
            cancelDictation()
            cancelGestures()
            onDismissMedia?()
        }
        isDiagnosing = active
        updateCapture()
    }

    func pressVirtualKey(_ id: String) {
        guard !isDiagnosing, learning == nil, calibrationConflict == nil, !isRunning,
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
        let context = foreground()
        if id == "home" { onDismissMedia?() }
        else if onMediaKey?(id, false) == true { return }
        guard let action = runtimeAction(id, context: context) else {
            feedback = L10n.tr("此键尚未分配动作")
            return
        }
        if action.isVoiceTrigger {
            feedback = L10n.tr("请按住实体语音键开始听写。")
        } else {
            perform(action, context: isGlobalSlot(id) ? nil : context)
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
        if let press = microphonePress, press.input == input, press.origin == origin {
            microphonePress = nil
            remoteMicrophone.voicePressDidEnd()
        }
        if let held = dictationInput, held.code == input, held.origin == origin {
            dictation.release()
            if !dictation.phase.active { dictationInput = nil }
        }
        if let held = heldVoice, held.input == input, held.origin == origin { endHeldVoice() }
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
        if let press = microphonePress, matches(press.input, press.origin) { cancelMicrophonePress() }
        if let held = dictationInput, matches(held.code, held.origin) { cancelDictation() }
        if let held = heldVoice, matches(held.input, held.origin) { endHeldVoice() }
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
        guard isEnabled, !isDiagnosing else { return }
        let key = visibleSlot.id
        let context = foreground()
        let captured = hid.captures(input, from: origin)
        if key == "home", isGlobalSlot(key) {
            cancelGestures()
            cancelDictation()
            onDismissMedia?()
            perform(.openFinder, context: nil)
            return
        }
        let action = runtimeAction(key, context: context)
        let nativePanelKey: Bool
        if case let .foregroundKey(shortcut) = AgentProfile.defaults.actions[key] {
            nativePanelKey = !captured && input.isNativeKeyboardShortcut(shortcut)
        } else { nativePanelKey = false }
        if onMediaKey?(key, nativePanelKey) == true {
            cancelGestures()
            return
        }
        if isGlobalSlot(key), let action {
            cancelDictation()
            perform(action, context: nil)
            return
        }
        guard !isRunning, !dictation.phase.active, heldVoice == nil else { return }
        if let action, action.isVoiceTrigger {
            startVoice(action, key: key, input: input, origin: origin, context: context)
            return
        }
        let hold = gestureAction(visibleSlot.holdSlot, for: visibleSlot, context: context)
        let double = gestureAction(visibleSlot.doubleSlot, for: visibleSlot, context: context)
        let baseline = remoteDefinition.manifest.defaults
        if !captured, input.hasNativeKeyboardEvent,
           remoteDefinition.slot(for: input) != key || action != baseline[key]
            || hold != baseline[visibleSlot.holdSlot] || double != baseline[visibleSlot.doubleSlot] {
            feedback = L10n.tr("当前设备无法可靠改绑，已保留原生按键。")
            return
        }
        if case let .finder(command) = action, command != .escape, let context, !finderSupportsNavigation(context) {
            if let native = command.nativeKey, captured {
                perform(.foregroundKey(native), context: context)
            }
            return
        }
        if remoteDefinition.manifest.behavior.deferredKeys.contains(key) || hold != nil || double != nil {
            startGesture(visibleSlot, input: input, origin: origin, context: context)
        } else if let action {
            dispatch(action, input: input, native: !captured, context: isGlobalSlot(key) ? nil : context)
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
        cancelMicrophonePress()
        endHeldVoice()
        dictationInput = nil
        dictation.cancel(L10n.tr("听写已取消，未发送。"))
    }

    private func cancelMicrophonePress() {
        microphonePress = nil
        remoteMicrophone.cancelRecording()
    }

    private func armMicrophone(input: InputCode, origin: RemoteInputOrigin?, context: ForegroundContext) {
        // An alternate key can trigger dictation, but it cannot authorize the physical microphone button.
        guard usesRemoteMicrophone, microphonePress == nil, remoteDefinition.slot(for: input) == "voice" else { return }
        microphonePress = (input, origin, context)
        remoteMicrophone.voicePressDidBegin()
    }

    private func startVoice(_ action: AgentAction, key: String, input: InputCode, origin: RemoteInputOrigin?,
                            context: ForegroundContext?) {
        guard let context, context.matches(foreground()) else { return }
        let nativeF5 = remoteDefinition.manifest.behavior.nativeDictationKeys.contains(key) && input.isKeyboardF5
        let captured = hid.captures(input, from: origin)
        if action == .dictation || action == .chatGPTDraft {
            guard context.bundleID == AppTarget.chatGPT.bundleID else { return }
            if nativeF5 && !captured {
                armMicrophone(input: input, origin: origin, context: context)
                feedback = L10n.tr("已保留原生 F5，请在 ChatGPT 确认听写。")
                return
            }
            if action == .dictation && !nativeF5 {
                guard canUseAccessibility else { requestedPermission = .accessibility; return }
                dictationInput = (input, origin)
                dictation.press()
                armMicrophone(input: input, origin: origin, context: context)
                return
            }
        }
        if input.hasNativeKeyboardEvent && !captured {
            feedback = L10n.tr("当前设备无法可靠改绑，已保留原生按键。")
            return
        }
        guard canPost else { requestedPermission = .accessibility; return }
        let shortcut: KeyboardShortcut
        let hold: Bool
        if case let .voiceShortcut(.macOS, keys) = action {
            shortcut = keys
            hold = false
        } else {
            shortcut = .init(keyCode: 96, modifiers: [], keyName: "F5")
            hold = true
        }
        do {
            // Dictation listeners can watch the session event stream. Posting
            // directly to the destination PID bypasses those listeners.
            try postVoice(shortcut, true)
            if hold { heldVoice = (input, origin, shortcut) }
            else { try postVoice(shortcut, false) }
            armMicrophone(input: input, origin: origin, context: context)
            error = nil
            feedback = L10n.tr("已触发语音快捷键，请确认识别结果。")
        } catch { self.error = error.localizedDescription }
    }

    private func endHeldVoice() {
        guard let held = heldVoice else { return }
        heldVoice = nil
        do { try postVoice(held.shortcut, false) }
        catch { self.error = error.localizedDescription }
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

    private func gestureAction(_ slot: String, for key: RemoteKey, context: ForegroundContext?) -> AgentAction? {
        guard key.actionSlots.contains(slot), let action = runtimeAction(slot, context: context),
              !action.isVoiceTrigger else { return nil }
        return action
    }

    private func sameFocus(_ context: ForegroundContext?) -> Bool {
        let current = foreground()
        return context.map { $0.matches(current) } ?? (current == nil)
    }

    private func startGesture(_ key: RemoteKey, input: InputCode, origin: RemoteInputOrigin?, context: ForegroundContext?) {
        guard gestures[key.id] == nil else { return }
        let now = ContinuousClock.now
        let pending = pendingTaps.removeValue(forKey: key.id)
        pending?.task.cancel()
        let secondTap = pending.map { now < $0.deadline && sameFocus($0.context) } ?? false
        if let pending, !secondTap {
            runGesture(key.id, for: key, input: pending.input, origin: pending.origin, context: pending.context)
        }

        var press = GesturePress(input: input, origin: origin, started: now, secondTap: secondTap, context: context)
        if let action = gestureAction(key.holdSlot, for: key, context: context) {
            press.holdTask = Task { [weak self, powerHoldDelay] in
                do { try await Task.sleep(until: now.advanced(by: powerHoldDelay), clock: .continuous) }
                catch { return }
                self?.fireHold(key)
                if case let .finder(command) = action, command.repeatsWhileHeld {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(130)) }
                        catch { return }
                        guard let self, self.gestures[key.id]?.firedHold == true, self.sameFocus(context) else { return }
                        self.runGesture(key.holdSlot, for: key, input: input, origin: origin, context: context)
                    }
                }
            }
        }
        gestures[key.id] = press
    }

    private func fireHold(_ key: RemoteKey) {
        guard var press = gestures[key.id], !press.firedHold else { return }
        press.firedHold = true
        gestures[key.id] = press
        runGesture(key.holdSlot, for: key, input: press.input, origin: press.origin, context: press.context)
    }

    private func finishGesture(_ input: InputCode, origin: RemoteInputOrigin?) {
        guard let id = gestures.first(where: { $0.value.input == input && $0.value.origin == origin })?.key,
              let press = gestures.removeValue(forKey: id), let key = keys.first(where: { $0.id == id }) else { return }
        press.holdTask?.cancel()
        guard !press.firedHold, sameFocus(press.context) else { return }
        let now = ContinuousClock.now
        let double = gestureAction(key.doubleSlot, for: key, context: press.context)
        let recognizesHold = gestureAction(key.holdSlot, for: key, context: press.context) != nil || double != nil
        if recognizesHold && press.started.duration(to: now) >= powerHoldDelay {
            runGesture(key.holdSlot, for: key, input: input, origin: origin, context: press.context)
        } else if press.secondTap {
            if hardwareDown == nil, hardwarePress?.key == key.id {
                hardwareTask?.cancel()
                hardwarePress = HardwarePress(key: key.id, phase: .doublePress)
                scheduleHardwareClear()
            }
            runGesture(key.doubleSlot, for: key, input: input, origin: origin, context: press.context)
        } else if double != nil {
            let deadline = now.advanced(by: doubleClickDelay)
            let task = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let self, self.pendingTaps.removeValue(forKey: key.id) != nil else { return }
                self.runGesture(key.id, for: key, input: input, origin: origin, context: press.context)
            }
            pendingTaps[key.id] = PendingTap(input: input, origin: origin, deadline: deadline, context: press.context, task: task)
        } else {
            runGesture(key.id, for: key, input: input, origin: origin, context: press.context)
        }
    }

    private func runGesture(_ slot: String, for key: RemoteKey, input: InputCode, origin: RemoteInputOrigin?,
                            context: ForegroundContext?) {
        guard isEnabled, canReadKeys, !isDiagnosing, learning == nil, calibrationConflict == nil,
              !dictation.phase.active, sameFocus(context),
              let action = gestureAction(slot, for: key, context: context) else { return }
        let captured = hid.captures(input, from: origin)
        if !captured, input.hasNativeKeyboardEvent,
           remoteDefinition.slot(for: input) != key.id || action != remoteDefinition.manifest.defaults[slot] { return }
        dispatch(action, input: input, native: slot == key.id && !captured, context: context)
    }

    private func dispatch(_ action: AgentAction, input: InputCode, native: Bool, context: ForegroundContext?) {
        if native {
            switch action {
            case let .foregroundKey(shortcut) where input.isNativeKeyboardShortcut(shortcut): return
            case .volumeUp where input.isNativeVolume(up: true): return
            case .volumeDown where input.isNativeVolume(up: false): return
            default: break
            }
        }
        perform(action, context: context)
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
        if isDiagnosing, let device = connectedDevice {
            diagnosticSignal = (device, down.key)
            if config.verifiedRemoteDevices?.contains(device) != true {
                var updated = config
                updated.verifiedRemoteDevices = (updated.verifiedRemoteDevices ?? []) + [device]
                save(updated)
            }
        }
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

    private func perform(_ action: AgentAction, context: ForegroundContext?) {
        guard !isRunning else { return }
        switch action {
        case .shortcut, .foregroundKey, .systemShortcut:
            guard canPost else { requestedPermission = .accessibility; return }
        case .appleMenu, .dictation, .finder:
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
        let target = context.map { current in
            apps.first { $0.bundleID == current.bundleID } ?? AppTarget(bundleID: current.bundleID)
        }
        let generation = contextGeneration
        Task {
            defer { isRunning = false }
            if let context, generation != contextGeneration || !context.matches(foreground()) { return }
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
            updateCapture()
            storageError = nil
            return true
        } catch {
            storageError = L10n.format("配置保存失败：%@", String(describing: error.localizedDescription))
            return false
        }
    }
}

extension InputCode {
    var keyboardUsage: Int? {
        guard collectionPage == 1, collectionUsage == 6, page == 7, value != 0 else { return nil }
        return usage == Int(UInt32.max) ? value : usage
    }

    private func isKeyboardUsage(_ key: Int) -> Bool {
        keyboardUsage == key
    }

    var isKeyboardF5: Bool {
        isKeyboardUsage(0x3E)
    }

    var hasNativeKeyboardEvent: Bool {
        keyboardUsage.map { (4...0xE7).contains($0) } ?? false
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
        case .openApp: L10n.tr("打开应用")
        case .openFinder: L10n.tr("打开访达")
        case .openLink: L10n.tr("打开网页")
        case .shortcut(AgentProfile.newChat): L10n.tr("新建对话")
        case .shortcut(AgentProfile.sendDraft): L10n.tr("发送当前草稿")
        case .shortcut(AgentProfile.stop): L10n.tr("停止生成")
        case .shortcut: L10n.tr("应用快捷键")
        case .chatBar: L10n.tr("打开 ChatGPT Chat Bar")
        case .nextAgent: L10n.tr("切换到下一个 Agent")
        case .dictation: L10n.tr("旧版 ChatGPT 听写（可自动发送）")
        case .chatGPTDraft: L10n.tr("ChatGPT 听写草稿")
        case let .voiceShortcut(provider, _): provider.title
        case let .finder(command): command.title
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
        case let .voiceShortcut(_, keys): keys.label
        case .chatBar: "⌥Space"
        case let .systemShortcut(keys): keys.label
        case .toggleDisplays: L10n.tr("短按关闭支持的外接屏并调低内置屏亮度，再按恢复")
        case .displaySleep: L10n.tr("唤醒时是否需要密码取决于 macOS 的「锁定屏幕」设置")
        default: nil
        }
    }
}

extension VoiceProvider {
    var title: String {
        switch self {
        case .macOS: L10n.tr("macOS 听写")
        case .weType: L10n.tr("无操作")
        }
    }
}

extension FinderCommand {
    var title: String {
        switch self {
        case .up: L10n.tr("向上选择")
        case .down: L10n.tr("向下选择")
        case .left: L10n.tr("向左选择")
        case .right: L10n.tr("向右选择")
        case .pageUp: L10n.tr("上一页")
        case .pageDown: L10n.tr("下一页")
        case .sidebar: L10n.tr("聚焦边栏")
        case .content: L10n.tr("聚焦内容")
        case .open: L10n.tr("打开所选项目")
        case .contextMenu: L10n.tr("所选项目的右键菜单")
        case .escape: "Esc"
        case .parent: L10n.tr("上一级文件夹")
        case .historyBack: L10n.tr("历史后退")
        }
    }
}
