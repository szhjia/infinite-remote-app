import Foundation
import RemoteCore
@testable import RemoteDesk
import Testing

@MainActor
private final class InputFixture: RemoteInputSource {
    let devices: [DeviceID]
    var state: InputMonitorState = .permission
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onMonitorState: (InputMonitorState) -> Void = { _ in }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void = { _, _ in }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void = { _ in }
    var capturesKeyboard = false
    var capturedUsages: Set<Int>?

    func captures(_ input: InputCode, from origin: RemoteInputOrigin?) -> Bool {
        capturesKeyboard && (capturedUsages.map { $0.contains(input.keyboardUsage ?? 0) } ?? true)
    }

    func press(_ device: DeviceID, _ input: InputCode) { onEvent(device, .pressed(input)) }
    var selectedDevice: DeviceID?

    init(devices: [DeviceID]) {
        self.devices = devices
    }

    func refresh() -> InputMonitorState {
        onDevices(devices)
        return state
    }
}

@Test @MainActor
func setupSeparatesHardwareConnectionFromPermissionListeningAndPause() {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                                   runAction: { _, _ in })

    #expect(model.readiness == .unpaired)
    model.refreshPermissions()
    #expect(model.connected)
    #expect(model.readiness == .needsInputMonitoring)
    input.onMonitorState(.failed(-1))
    #expect(model.readiness == .monitorUnavailable)
    input.onMonitorState(.listening)
    #expect(model.readiness == .listening)
    model.isEnabled = false
    #expect(model.readiness == .paused)
    model.setDiagnosing(true)
    #expect(model.readiness == .diagnosing)
    model.setDiagnosing(false)
    #expect(model.readiness == .paused)
}

@Test @MainActor
func setupShowsAccessibilityWhileShortcutPermissionCatchesUp() {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    var accessibilityAllowed = false
    var listeningAllowed = false
    var postingAllowed = false
    let model = fixtureRemoteModel(
        hid: input, storeURL: directory.appending(path: "configuration.json"),
        permissions: .init(postEvents: { postingAllowed }, accessibility: { accessibilityAllowed },
                           listenEvents: { listeningAllowed }),
        runAction: { _, _ in }
    )

    model.refreshPermissions()
    #expect(SetupReadiness(model: model).connected)
    #expect(PermissionKind.accessibility.status(in: model) == .notAllowed)
    #expect(PermissionKind.inputMonitoring.status(in: model) == .notAllowed)
    #expect(!SetupReadiness(model: model).needsSeparateInputAuthorization)
    #expect(!model.shortcutsNeedRestart)

    listeningAllowed = true
    input.state = .listening
    model.refreshPermissions()
    #expect(PermissionKind.inputMonitoring.status(in: model) == .allowed)
    #expect(!SetupReadiness(model: model).canFinish)

    // macOS can grant listening with Accessibility while event posting still needs a relaunch.
    accessibilityAllowed = true
    model.refreshPermissions()
    #expect(PermissionKind.accessibility.status(in: model) == .allowed)
    #expect(PermissionKind.inputMonitoring.status(in: model) == .coveredByAccessibility)
    #expect(!SetupReadiness(model: model).needsSeparateInputAuthorization)
    #expect(model.shortcutsNeedRestart)
    #expect(!SetupReadiness(model: model).canFinish)

    postingAllowed = true
    model.refreshPermissions()
    #expect(!model.shortcutsNeedRestart)
    #expect(SetupReadiness(model: model).canFinish)

    listeningAllowed = false
    input.state = .permission
    model.refreshPermissions()
    #expect(SetupReadiness(model: model).needsSeparateInputAuthorization)
    #expect(!SetupReadiness(model: model).canFinish)
}

@Test @MainActor
func diagnosticVerificationRequiresAFreshPhysicalPressAndReleaseAndSurvivesReload() throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote")
    let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                          usage: Int(UInt32.max), report: 1, value: 0x28)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    let input = InputFixture(devices: [device])
    input.state = .listening
    let model = fixtureRemoteModel(hid: input, storeURL: storeURL, runAction: { _, _ in
        Issue.record("A diagnostic press must not execute an action")
    })
    model.refreshPermissions()
    model.isEnabled = false
    model.pressVirtualKey("ok")
    #expect(!model.hasVerifiedInput)
    input.press(device, enter)
    model.isEnabled = true
    model.setDiagnosing(true)
    input.onEvent(device, .released(enter))
    #expect(!model.hasVerifiedInput)
    input.press(device, enter)
    #expect(!model.hasVerifiedInput)
    input.onEvent(device, .released(enter))
    #expect(model.hasVerifiedInput)
    #expect(model.diagnosticKeyName != nil)
    #expect(!model.isRunning)
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storeURL))
    #expect(saved.verifiedRemoteDevices == [device])
    model.setDiagnosing(false)
    #expect(model.readiness == .listening)

    let reopened = RemoteModel(hid: input, storeURL: storeURL, runAction: { _, _ in })
    reopened.refreshPermissions()
    #expect(reopened.hasVerifiedInput)
    #expect(reopened.diagnosticKeyName == nil)
    input.onDevices([])
    #expect(!reopened.hasVerifiedInput)
}

@Test @MainActor
func hardwareListenerChangesUpdateReadinessWithoutRefreshingPermissions() {
    let remote = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [remote])
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })

    model.refreshPermissions()
    model.selectDevice(remote)
    input.onMonitorState(.listening)
    #expect(model.canReadKeys)
    model.startLearning()
    #expect(model.learning != nil)

    input.onMonitorState(.failed(-536_870_201))
    #expect(!model.canReadKeys)
    #expect(model.learning == nil)

    input.onMonitorState(.listening)
    #expect(model.canReadKeys)
    input.onDevices([])
    input.onMonitorState(.idle)
    #expect(!model.canReadKeys)

    input.onDevices([remote])
    input.onMonitorState(.listening)
    #expect(model.canReadKeys)
}

@Test(arguments: [false, true]) @MainActor
func upgradesOldCodexPresetWithoutChangingLearnedKeysOrCustomizedActions(customized: Bool) throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: Int(UInt32.max), report: 1, value: 0x28)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")

    var old = Configuration()
    old.version = 1
    old.selectDevice(device, layout: .xiaomi2Pro)
    old.updateRemote { $0.learn(enter, as: "ok") }
    let custom = KeyboardShortcut(keyCode: 0, modifiers: [.command, .shift], keyName: "A")
    old.activeAgentID = "chatgpt"
    old.agents = [
        .init(id: "chatgpt", name: "ChatGPT", target: .init(bundleID: "com.openai.chat"),
              actions: ["ok": .openLink("https://chatgpt.com/")]),
        .init(id: "codex", name: "Codex", target: .init(bundleID: "com.openai.codex"),
              actions: ["ok": customized ? .shortcut(custom) : .openApp, "menu": .nextAgent, "key1": .openApp])
    ]
    let original = try JSONEncoder().encode(old)
    try original.write(to: storeURL)

    let model = fixtureRemoteModel(hid: InputFixture(devices: [device]), storeURL: storeURL, runAction: { _, _ in })
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storeURL))
    #expect(saved == model.config)
    #expect(saved.version == Configuration.currentVersion)
    #expect(saved.activeAgentID == "codex")
    #expect(saved.remotes == old.remotes)
    #expect(saved.agents.count == 1)
    #expect(saved.agents.allSatisfy { $0.modelID == RemoteDefinition.xiaomiID })
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v1.backup")) == original)

    let codex = try #require(saved.activeAgent)
    #expect(codex.name == "ChatGPT")
    #expect(codex.actions["menu"] == .appleMenu)
    #expect(codex.actions["power"] == .toggleDisplays)
    #expect(codex.actions["power-long"] == .lockScreen)
    #expect(codex.actions["voice"] == .dictation)
    #expect(codex.actions["ok"] == .shortcut(customized ? custom : AgentProfile.sendDraft))
    #expect(codex.actions["home"] == (customized ? nil : .shortcut(AgentProfile.newChat)))
    #expect(codex.actions["back"] == (customized ? nil : .shortcut(AgentProfile.stop)))
}

@Test @MainActor
func restoresLastSavedProfileAndUpdatesOnlyTheOldChatGPTPreset() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    func openModel() -> RemoteModel {
        fixtureRemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    }

    #expect(openModel().profile == legacyModelProfile(.defaults))

    var previousPreset = AgentProfile.chatGPT
    previousPreset.actions["power"] = .displaySleep
    previousPreset.actions.removeValue(forKey: "power-long")
    let custom = AgentProfile(name: "自定义", target: previousPreset.target, actions: previousPreset.actions)
    var previous = Configuration()
    previous.version = 4
    previous.agents = [previousPreset, custom]
    previous.activeAgentID = custom.id
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = try JSONEncoder().encode(previous)
    try original.write(to: storeURL)

    let migrated = openModel()
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v4.backup")) == original)
    #expect(migrated.profile == legacyModelProfile(custom))
    #expect(migrated.profiles.contains(legacyModelProfile(.chatGPT)))
    #expect(migrated.selectProfile(AgentProfile.chatGPT.id))
    #expect(openModel().editableActions["power-long"] == .lockScreen)

    migrated.setAction(nil, for: "power-long")
    #expect(migrated.saveConfigurationChanges())
    var editedPreset = AgentProfile.chatGPT
    editedPreset.actions.removeValue(forKey: "power-long")
    #expect(openModel().profile == legacyModelProfile(editedPreset))
}

@Test @MainActor
func selectedRemoteLearnsOnceAndRunsTheChatGPTActionAfterRestart() async throws {
    let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let other = DeviceID(vendor: 1, product: 2, name: "另一个遥控器")
    // IOKit reports this remote's keyboard array usage in the value field.
    let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: Int(UInt32.max), report: 1, value: 0x28)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")

    var dispatched: [(AgentAction, AppTarget?)] = []
    // Version 3 users keep their existing active ChatGPT preset and mappings.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var old = Configuration()
    old.version = 3
    old.agents = [.chatGPT]
    old.activeAgentID = AgentProfile.chatGPT.id
    let original = try JSONEncoder().encode(old)
    try original.write(to: storeURL)

    let runAction: @MainActor (AgentAction, AppTarget?) async throws -> Void = { action, target in
        dispatched.append((action, target))
    }
    let input = InputFixture(devices: [xiaomi, other])
    let model = fixtureRemoteModel(hid: input, storeURL: storeURL, runAction: runAction)
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v3.backup")) == original)
    #expect(model.profiles.first == legacyModelProfile(.defaults))

    model.refreshPermissions()
    model.selectDevice(xiaomi)
    #expect(model.connected)
    #expect(input.selectedDevice == xiaomi)
    #expect(model.devices == [xiaomi])
    model.startLearning()
    #expect(model.learning == nil)

    input.state = .listening
    model.refreshPermissions()
    model.startLearning()
    input.press(other, enter)
    #expect(model.learning == "ok")
    input.press(xiaomi, enter)
    #expect(model.learning == nil)
    #expect(model.editableRemote?.keys.count == 1)
    #expect(!model.isRunning)

    let customShortcut = RemoteCore.KeyboardShortcut(keyCode: 45, modifiers: [.command], keyName: "N")
    model.setAction(.shortcut(customShortcut), for: "ok")
    #expect(model.hasConfigurationChanges)
    #expect(model.profile?.actions["ok"] == .shortcut(AgentProfile.sendDraft))
    #expect(model.config.activeRemote?.input(for: "ok") == nil)
    model.pressVirtualKey("ok")
    try await waitForAction(on: model)
    #expect(dispatched.map(\.0) == [.shortcut(AgentProfile.sendDraft)])
    model.saveConfigurationChanges()
    #expect(!model.hasConfigurationChanges)

    let reopenedInput = InputFixture(devices: [xiaomi, other])
    let reopened = fixtureRemoteModel(hid: reopenedInput, storeURL: storeURL, runAction: runAction)
    #expect(reopenedInput.selectedDevice == xiaomi)
    #expect(reopened.editableRemote?.keys.count == 1)

    reopened.refreshPermissions()
    reopenedInput.press(xiaomi, enter)
    #expect(!reopened.isRunning)

    reopenedInput.state = .listening
    reopened.refreshPermissions()
    reopened.isEnabled = false
    reopenedInput.press(xiaomi, enter)
    #expect(!reopened.isRunning)

    reopened.isEnabled = true
    reopenedInput.capturesKeyboard = true
    reopenedInput.press(xiaomi, enter)
    try await waitForAction(on: reopened)
    try #require(dispatched.count == 2)
    #expect(dispatched[1].0 == .shortcut(customShortcut))
    #expect(dispatched[1].1?.bundleID == "com.openai.codex")

    reopenedInput.press(other, enter)
    #expect(!reopened.isRunning)
    #expect(dispatched.count == 2)
}

@MainActor
private func waitForAction(on model: RemoteModel) async throws {
    try #require(model.isRunning)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.isRunning && clock.now < deadline {
        try await clock.sleep(for: .milliseconds(5))
    }
    try #require(!model.isRunning)
}

@Test @MainActor
func unregisteredRemoteCannotEnableVirtualButtons() {
    let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let other = DeviceID(vendor: 1, product: 2, name: "通用遥控器")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [xiaomi, other])
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })
    model.refreshPermissions()
    #expect(model.connectedDevice == xiaomi)
    #expect(model.connected)
    #expect(!model.canReadKeys)
    input.onDevices([other])
    #expect(model.connectedDevice == nil)
    #expect(!model.connected)

    model.selectDevice(other)
    #expect(model.connectedDevice == nil)
    #expect(!model.connected)
}

@Test @MainActor
func diagnosticsSuspendHardwareAndVirtualActionsUntilClosed() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: Int(UInt32.max), report: 1, value: 0x28)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    input.state = .listening
    var dispatched: [AgentAction] = []
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
        dispatched.append(action)
    }
    model.refreshPermissions()
    model.selectDevice(device)

    model.startLearning()
    input.press(device, enter)
    #expect(model.editableRemote?.keys.count == 1)
    model.saveConfigurationChanges()

    model.startLearning()
    model.setDiagnosing(true)
    #expect(model.learning == nil)
    model.startLearning()
    #expect(model.learning == nil)
    let count = model.activity.count
    input.press(device, enter)
    model.pressVirtualKey("ok")
    #expect(model.activity.count == count + 1)
    #expect(!model.isRunning)
    #expect(dispatched.isEmpty)

    model.setDiagnosing(false)
    model.isEnabled = false
    model.pressVirtualKey("ok")
    #expect(!model.isRunning)
    model.isEnabled = true
    model.pressVirtualKey("ok")
    try await waitForAction(on: model)
    #expect(dispatched == [AgentProfile.defaults.actions["ok"]!])
    input.onDevices([])
    model.pressVirtualKey("ok")
    #expect(!model.isRunning)
}

@Test @MainActor
func powerDispatchesExactlyOneActionAndDropsInterruptedPresses() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let code = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x30, report: 1, value: 1)
    let origin = RemoteInputOrigin(endpoint: 8, cookie: 1)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched: [AgentAction] = []
    var gestureTime: ContinuousClock.Instant?
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            powerHoldDelay: .milliseconds(50), gestureNow: { gestureTime ?? .now }) { action, _ in dispatched.append(action) }
    model.refreshPermissions()
    model.selectSlot("power")
    model.startLearning()
    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .released(code, origin: origin))
    #expect(model.saveConfigurationChanges())

    gestureTime = .now
    input.onEvent(device, .pressed(code, origin: origin))
    #expect(dispatched.isEmpty)
    input.onEvent(device, .released(code, origin: origin))
    gestureTime = nil
    try await waitForAction(on: model)
    try #require(dispatched == [.toggleDisplays])

    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .pressed(code, origin: origin))
    try await waitUntil { dispatched.count == 2 && !model.isRunning }
    input.onEvent(device, .released(code, origin: origin))
    #expect(dispatched == [.toggleDisplays, .lockScreen])

    input.onEvent(device, .pressed(code, origin: origin))
    model.isEnabled = false
    model.isEnabled = true
    input.onEvent(device, .released(code, origin: origin))
    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .endpointClosed(origin.endpoint))
    try await Task.sleep(for: .milliseconds(80))
    #expect(dispatched == [.toggleDisplays, .lockScreen])
}

@Test @MainActor
func namedProfilesAndImportsCannotOverwriteTheBuiltInOrLoseDrafts() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    let model = fixtureRemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    model.setAction(.appleMenu, for: "back")
    #expect(!model.saveConfigurationChanges())
    #expect(!model.saveConfigurationChanges(as: " \(L10n.tr("默认配置")) "))
    #expect(!model.saveConfigurationChanges(as: L10n.tr("Codex 续聊（实验）")))
    #expect(model.profile == legacyModelProfile(.defaults))
    #expect(model.saveConfigurationChanges(as: " Café "))
    let saved = try #require(model.profile)
    #expect(saved.modelID == RemoteDefinition.xiaomiID)
    let file = directory.appending(path: "profile.json")
    try ProfileArchive(saved).write(to: file)
    let archive = try ProfileArchive.read(from: file)
    #expect(archive.target == .chatGPT)
    #expect(!model.importProfile(archive, as: "cafe\u{301}", discardingDraft: false))
    model.restoreDefaultActions()
    #expect(!model.selectProfile(AgentProfile.defaults.id))
    #expect(!model.importProfile(archive, as: "备份", discardingDraft: false))
    #expect(model.hasConfigurationChanges)
    #expect(model.importProfile(archive, as: "备份", discardingDraft: true))
    let reopened = fixtureRemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    #expect(reopened.profiles.map(\.name) == [L10n.tr("默认配置"), L10n.tr("Codex 续聊（实验）"), "Café", "备份"])
    #expect(reopened.profile?.actions["back"] == .appleMenu)
    #expect(reopened.profiles.allSatisfy { $0.modelID == RemoteDefinition.xiaomiID })
    #expect(reopened.profiles.first == legacyModelProfile(.defaults))
}

@Test @MainActor
func xiaomiButtonsWorkWithoutLearningAndUseTheSavedAction() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched: [AgentAction] = []
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
        dispatched.append(action)
    }
    model.refreshPermissions()
    func press(_ usage: Int) {
        input.press(device, InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                                      usage: Int(UInt32.max), report: 1, value: usage))
    }

    press(0x80)
    try await waitForAction(on: model)
    press(0x81)
    try await waitForAction(on: model)
    #expect(dispatched == [.volumeUp, .volumeDown])
    press(0x52)
    #expect(model.hardwarePress?.key == "up")
    #expect(!model.isRunning) // The system already delivers this arrow event.
    var openedSwitcher = false
    model.onSwitchApps = { openedSwitcher = true }
    press(0x65)
    #expect(openedSwitcher)

    model.setAction(.showDesktop, for: "plus")
    #expect(model.hasConfigurationChanges)
    #expect(model.saveConfigurationChanges(as: "自定义"))
    input.capturesKeyboard = true
    press(0x80)
    try await waitForAction(on: model)
    #expect(dispatched == [.volumeUp, .volumeDown, .showDesktop])
    #expect(model.editableRemote?.keys.isEmpty == true)
}

@Test(arguments: [0x35, 0x65]) @MainActor
func xiaomiChooserStaysOpenAfterOnePressWithMultipleHIDReports(usage: Int) {
    let key = [0x35: "tv", 0x65: "menu"][usage]!
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let array = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                          usage: Int(UInt32.max), report: 1, value: usage)
    let direct = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                           usage: usage, report: 1, value: 1)
    let packed = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                           usage: Int(UInt32.max), report: 1, value: usage << 16)
    let packedOrigin = RemoteInputOrigin(endpoint: 8, cookie: 3)
    let arrayOrigin = RemoteInputOrigin(endpoint: 8, cookie: 1)
    let directOrigin = RemoteInputOrigin(endpoint: 8, cookie: 2)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            runAction: { _, _ in })
    model.refreshPermissions()
    var visible = false
    var toggles = 0
    model.onSwitchApps = { visible = true; toggles += 1 }
    model.onShowMedia = { visible = true; toggles += 1 }
    model.onMediaKey = { slot, _ in
        guard visible, slot == key else { return false }
        visible = false
        toggles += 1
        return true
    }

    input.onEvent(device, .pressed(array, origin: arrayOrigin))
    input.onEvent(device, .pressed(direct, origin: directOrigin))
    input.onEvent(device, .pressed(packed, origin: packedOrigin))
    #expect(visible)
    #expect(toggles == 1)
    input.onEvent(device, .released(array, origin: arrayOrigin))
    input.onEvent(device, .released(direct, origin: directOrigin))
    input.onEvent(device, .released(packed, origin: packedOrigin))
    #expect(visible)

    input.onEvent(device, .pressed(direct, origin: directOrigin))
    input.onEvent(device, .pressed(array, origin: arrayOrigin))
    #expect(!visible)
    #expect(toggles == 2)
}

@Test(arguments: [false, true]) @MainActor
func xiaomiHomeReportsAreOnePressDuringLearningAndAfterRemapping(directFirst: Bool) throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let array = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                          usage: Int(UInt32.max), report: 1, value: 0x4A)
    let direct = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                           usage: 0x4A, report: 1, value: 1)
    let reports: [(InputCode, RemoteInputOrigin)] = [
        (array, .init(endpoint: 8, cookie: 1)),
        (direct, .init(endpoint: 8, cookie: 2))
    ]
    let learningOrder = directFirst ? Array(reports.reversed()) : reports
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            runAction: { _, _ in })
    model.refreshPermissions()
    var switches = 0
    var mediaOpenings = 0
    model.onSwitchApps = { switches += 1 }
    model.onShowMedia = { mediaOpenings += 1 }

    model.selectSlot("tv")
    model.startLearning()
    try #require(model.learning == "tv")
    for (code, origin) in learningOrder {
        input.onEvent(device, .pressed(code, origin: origin))
    }
    #expect(switches == 0)
    #expect(mediaOpenings == 0)
    #expect(model.editableRemote?.input(for: "tv") == nil)
    #expect(model.calibrationConflict?.previous == "home")
    #expect(!model.saveConfigurationChanges())
    model.resolveCalibrationConflict(transfer: true)
    #expect(model.editableRemote?.input(for: "tv") == learningOrder[0].0)
    try #require(model.saveConfigurationChanges())
    for (code, origin) in learningOrder {
        input.onEvent(device, .released(code, origin: origin))
    }

    // The unrecorded report can arrive first on the next physical press.
    for (code, origin) in learningOrder.reversed() {
        input.onEvent(device, .pressed(code, origin: origin))
    }
    #expect(switches == 0)
    #expect(mediaOpenings == 1)
}

@Test @MainActor
func xiaomiDirectionsRouteOneSwitcherMovePerPhysicalPress() throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let input = InputFixture(devices: [device])
    input.state = .listening
    input.capturesKeyboard = true
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = RemoteCatalog(directory: directory.appending(path: "RemoteModels"))
    let package = try #require(Bundle.module.url(forResource: "xiaomi-2-pro", withExtension: nil,
                                                subdirectory: "Fixtures/Packages"))
    _ = try catalog.install(package, configuredSlotsByModel: [:])
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
        Issue.record("Unexpected action while switching apps: \(action)")
    }
    model.refreshPermissions()
    var visible = false
    var moves: [String] = []
    model.onSwitchApps = { visible = true }
    model.onMediaKey = { slot, nativeKeyboard in
        guard visible else { return false }
        #expect(!nativeKeyboard)
        moves.append(slot)
        return true
    }
    input.press(device, .init(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x65, report: 1, value: 1))
    try #require(visible)

    for (slot, usage) in [("right", 0x4F), ("left", 0x50), ("down", 0x51), ("up", 0x52)] {
        let array = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                              usage: Int(UInt32.max), report: 1, value: usage)
        let discrete = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                                 usage: usage, report: 1, value: 1)
        let reports = [(array, RemoteInputOrigin(endpoint: 8, cookie: 1)),
                       (discrete, RemoteInputOrigin(endpoint: 8, cookie: usage))]
        moves.removeAll()
        for order in [reports, Array(reports.reversed())] {
            for (code, origin) in order { input.onEvent(device, .pressed(code, origin: origin)) }
            for (code, origin) in order { input.onEvent(device, .released(code, origin: origin)) }
        }
        #expect(moves == [slot, slot])
    }
}

@Test @MainActor
func mediaAndRunningAppChoosersConsumeNavigationBeforeConfiguredActions() throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let tv = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x61, report: 1, value: 1)
    let right = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x42, report: 1, value: 1)
    let menu = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x45, report: 1, value: 1)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    input.state = .listening
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
        Issue.record("Unexpected action while selecting media: \(action)")
    }
    model.refreshPermissions()
    for (slot, code) in [("tv", tv), ("right", right), ("menu", menu)] {
        model.selectSlot(slot)
        model.startLearning()
        input.press(device, code)
    }
    try #require(model.saveConfigurationChanges())

    var showing = false
    var switchingApps = false
    var navigation: [String] = []
    model.onShowMedia = { showing = true }
    model.onSwitchApps = { showing = true; switchingApps = true }
    model.onDismissMedia = { showing = false }
    model.onMediaKey = { slot, nativeKeyboard in
        guard showing else { return false }
        #expect(!nativeKeyboard)
        navigation.append(slot)
        return true
    }
    input.press(device, tv)
    #expect(showing)
    input.press(device, right)
    #expect(navigation == ["right"])
    #expect(!model.isRunning)
    model.isEnabled = false
    #expect(!showing)
    model.isEnabled = true
    input.press(device, menu)
    #expect(showing && switchingApps)
    input.press(device, right)
    #expect(navigation == ["right", "right"])
}

@MainActor
private final class DictationFixture: DictationSession {
    var starts = 0
    var stops = 0
    var sends = 0
    var cancellations = 0
    var resultReady = false
    var contextChanged = false

    func begin() -> any DictationSession {
        starts += 1
        return self
    }

    func isRecording() throws -> Bool {
        if contextChanged { throw DictationFailure.contextChanged }
        return true
    }

    func stop() throws {
        if contextChanged { throw DictationFailure.contextChanged }
        stops += 1
    }

    func submitTranscriptIfReady() throws -> DictationSubmission {
        if contextChanged { throw DictationFailure.contextChanged }
        guard resultReady else { return .waitingForTranscript }
        if sends == 0 {
            sends += 1
            return .awaitingConfirmation
        }
        return .confirmed
    }

    func cancel() { cancellations += 1 }
}

@Test @MainActor
func voiceShortPressDoesNotRecordAndPhysicalReleaseSubmitsOnlyOnce() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let code = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 5, report: 1, value: 1)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let driver = DictationFixture()
    let dictation = DictationController(holdDelay: .milliseconds(15), begin: driver.begin)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            dictation: dictation, runAction: { _, _ in })
    model.refreshPermissions()
    model.setAction(.dictation, for: "voice")
    try #require(model.saveConfigurationChanges(as: "Legacy dictation"))
    model.selectSlot("voice")
    model.startLearning()
    input.onEvent(device, .pressed(code))
    input.onEvent(device, .released(code))
    model.saveConfigurationChanges()

    input.onEvent(device, .pressed(code))
    #expect(model.hardwarePress?.key == "voice")
    #expect(model.hardwarePress?.phase == .down)
    input.onEvent(device, .released(code))
    #expect(model.hardwarePress?.phase == .shortPress)
    #expect(dictation.phase == .idle)
    #expect(driver.starts == 0)

    let origin = RemoteInputOrigin(endpoint: 11, cookie: 2)
    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .pressed(code, origin: origin))
    try await waitUntil { dictation.phase == .recording && model.hardwarePress?.phase == .holding }
    #expect(driver.starts == 1)
    input.onEvent(device, .released(code, origin: .init(endpoint: 12, cookie: 2)))
    #expect(dictation.phase == .recording)
    #expect(model.hardwarePress?.phase == .holding)
    input.onEvent(device, .released(code, origin: origin))
    input.onEvent(device, .released(code, origin: origin))
    #expect(dictation.phase == .transcribing)
    #expect(model.hardwarePress?.phase == .longPress)
    #expect(driver.sends == 0)
    driver.resultReady = true
    try await waitUntil { dictation.phase == .sent }
    #expect(driver.stops == 1)
    #expect(driver.sends == 1)
    #expect(model.activity.contains { $0.text == L10n.format("松开 · %@%@", "语音 · ", code.label) })
}

@Test(arguments: [true, false]) @MainActor
func xiaomiKeyboardF5ShowsLongPressWithoutStartingOrSubmittingAXDictation(_ arrayReport: Bool) async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let code = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                         usage: arrayReport ? Int(UInt32.max) : 0x3E,
                         report: 1, value: arrayReport ? 0x3E : 1)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let driver = DictationFixture()
    let dictation = DictationController(holdDelay: .milliseconds(15), begin: driver.begin)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            dictation: dictation, runAction: { _, _ in })
    model.refreshPermissions()
    model.selectSlot("voice")
    model.startLearning()
    input.onEvent(device, .pressed(code))
    input.onEvent(device, .released(code))
    model.saveConfigurationChanges()

    input.onEvent(device, .pressed(code))
    try await waitUntil { model.hardwarePress?.phase == .holding }
    input.onEvent(device, .released(code))

    #expect(model.hardwarePress?.phase == .longPress)
    #expect(dictation.phase == .idle)
    #expect(driver.starts == 0)
    #expect(driver.sends == 0)
}

@Test(arguments: ["disconnect", "pause", "context", "permission", "ambiguity", "endpoint"]) @MainActor
func dictationNeverSubmitsAfterAnInterruption(_ interruption: String) async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let code = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 5, report: 1, value: 1)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let driver = DictationFixture()
    let dictation = DictationController(holdDelay: .zero, begin: driver.begin)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            dictation: dictation, runAction: { _, _ in })
    model.refreshPermissions()
    model.setAction(.dictation, for: "voice")
    try #require(model.saveConfigurationChanges(as: "Legacy dictation"))
    model.selectSlot("voice")
    model.startLearning()
    input.onEvent(device, .pressed(code))
    input.onEvent(device, .released(code))
    model.saveConfigurationChanges()
    let origin = RemoteInputOrigin(endpoint: 19, cookie: 1)
    input.onEvent(device, .pressed(code, origin: origin))
    try await waitUntil { dictation.phase == .recording }
    input.onEvent(device, .released(code, origin: origin))
    #expect(dictation.phase == .transcribing)

    switch interruption {
    case "disconnect": input.onDevices([])
    case "pause": model.isEnabled = false
    case "context": driver.contextChanged = true
    case "permission": input.onMonitorState(.permission)
    case "ambiguity": input.onAmbiguousDevices([device])
    case "endpoint": input.onEvent(device, .endpointClosed(19))
    default: Issue.record("Unexpected interruption")
    }
    driver.resultReady = true
    try await waitUntil { !dictation.phase.active }
    #expect(driver.sends == 0)
    #expect(driver.cancellations == 1)
}

@Test @MainActor
func dictationRefusesAnExistingDraftBeforeOpeningSession() async throws {
    let dictation = DictationController(holdDelay: .zero, begin: { throw DictationFailure.draft })
    dictation.press()
    try await waitUntil { !dictation.phase.active }
    #expect(dictation.phase == .failed(DictationFailure.draft.localizedDescription))
    dictation.release()
    #expect(dictation.phase != .sent)
}

@Test @MainActor
func systemShortcutRequiresTheSameEnabledCombination() throws {
    let original = SystemHotKey(keyCode: 120, flags: 262144)
    let rebound = SystemHotKey(keyCode: 120, flags: 524288)
    try SystemActions.validate(original, enabled: [original])
    #expect(throws: SystemActions.Failure.shortcutChanged) { try SystemActions.validate(original, enabled: [rebound]) }
    #expect(throws: SystemActions.Failure.shortcutChanged) { try SystemActions.validate(original, enabled: []) }
}

@MainActor
private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    // The timeout detects a stalled transition; the behavior under test is the state, not main-actor scheduling latency.
    let deadline = clock.now.advanced(by: .seconds(10))
    while !condition() && clock.now < deadline {
        try await clock.sleep(for: .milliseconds(5))
    }
    try #require(condition(), sourceLocation: sourceLocation)
}

@Test @MainActor
func xiaomiVolumeGesturesRetireOnlyWhenSavedProfilesDoNotUseThem() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let package = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/Packages/xiaomi-2-pro"))
    let oldPackage = directory.appending(path: "old")
    try files.copyItem(at: package, to: oldPackage)
    let oldManifest = oldPackage.appending(path: "manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: oldManifest)) as? [String: Any])
    manifest["release"] = "0.0.1"
    manifest["retiredGestureSlots"] = nil
    try JSONSerialization.data(withJSONObject: manifest).write(to: oldManifest)
    let oldLayout = oldPackage.appending(path: "layout.json")
    var layout = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: oldLayout)) as? [String: Any])
    var keys = try #require(layout["keys"] as? [[String: Any]])
    let volumeUp = try #require(keys.firstIndex { $0["id"] as? String == "plus" })
    keys[volumeUp]["doublePress"] = true
    keys[volumeUp]["longPress"] = true
    layout["keys"] = keys
    try JSONSerialization.data(withJSONObject: layout).write(to: oldLayout)

    let model = RemoteModel(hid: InputFixture(devices: []), storeURL: directory.appending(path: "configuration.json"),
                            runAction: { _, _ in })
    try model.installModel(from: oldPackage)
    model.setAction(.showDesktop, for: "plus-double")
    #expect(model.saveConfigurationChanges(as: "Volume gesture"))
    let customProfile = try #require(model.profile?.id)
    #expect(model.selectProfile(AgentProfile.defaults.id))
    #expect(throws: RemotePackageError.self) { try model.installModel(from: package) }
    #expect(model.remoteDefinition.manifest.release == "0.0.1")
    #expect(model.selectProfile(customProfile))
    #expect(model.editableActions["plus-double"] == .showDesktop)
    model.setAction(nil, for: "plus-double")
    #expect(model.saveConfigurationChanges())
    try model.installModel(from: package)
    #expect(model.selectProfile(AgentProfile.defaults.id))
    for (id, action) in [("plus", AgentAction.volumeUp), ("minus", .volumeDown)] {
        let key = try #require(model.keys.first { $0.id == id })
        #expect(key.actionSlots == [id])
        #expect(model.editableActions[id] == action)
    }
}

@Test @MainActor
func importsOfflineModelAndRoutesItsHardwareWithoutSharingXiaomiActions() async throws {
    let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米")
    let device = DeviceID(vendor: 0x1234, product: 0x5678, name: "Test Remote")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appending(path: "Fixture")
    let storeURL = directory.appending(path: "configuration.json")
    let input = InputFixture(devices: [])
    let model = fixtureRemoteModel(hid: input, storeURL: storeURL, runAction: { _, _ in })
    try writeFixturePackage(package, image: model.remoteDefinition.front)
    try model.installModel(from: package)

    #expect(model.remoteDefinition.id == "test-remote")
    #expect(model.keys.map(\.id) == ["play", "stop"])
    #expect(model.profile?.actions.isEmpty == true)
    model.setAction(.showDesktop, for: "play")
    #expect(model.saveConfigurationChanges(as: "自定义"))
    model.previewModel(RemoteDefinition.xiaomiID)
    #expect(model.profile?.actions["power"] == .toggleDisplays)
    #expect(!model.profiles.contains { $0.name == "自定义" })

    try FileManager.default.removeItem(at: package)
    let secondInput = InputFixture(devices: [device, xiaomi])
    secondInput.state = .listening
    var dispatched: [AgentAction] = []
    let reloaded = fixtureRemoteModel(hid: secondInput, storeURL: storeURL) { action, _ in dispatched.append(action) }
    reloaded.refreshPermissions()
    reloaded.selectDevice(device)
    #expect(reloaded.connectedDevice == device)
    #expect(reloaded.profile?.name == "自定义")
    #expect(reloaded.profile?.modelID == "test-remote")

    let signal = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 205, report: 2, value: 1)
    secondInput.press(xiaomi, signal)
    #expect(!reloaded.isRunning)
    secondInput.press(device, signal)
    try await waitForAction(on: reloaded)
    #expect(dispatched == [.showDesktop])
    secondInput.onEvent(device, .released(signal))

    reloaded.selectSlot("stop")
    reloaded.startLearning()
    secondInput.press(device, signal)
    #expect(reloaded.calibrationConflict?.previous == "play")
    #expect(reloaded.editableRemote?.slot(for: signal) == nil)
    #expect(!reloaded.saveConfigurationChanges())
    reloaded.resolveCalibrationConflict(transfer: false)
    #expect(reloaded.editableRemote?.slot(for: signal) == nil)
    reloaded.startLearning()
    secondInput.onEvent(device, .released(signal))
    secondInput.press(device, signal)
    reloaded.resolveCalibrationConflict(transfer: true)
    #expect(reloaded.editableRemote?.slot(for: signal) == "stop")
    #expect(reloaded.saveConfigurationChanges())
    secondInput.onEvent(device, .released(signal))
    secondInput.press(device, signal)
    #expect(reloaded.hardwarePress?.key == "stop")
    #expect(dispatched == [.showDesktop])
}

@Test @MainActor
func invalidOrConflictingModelDoesNotReplaceInstalledPackage() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = fixtureCatalog(directory: directory.appending(path: "Installed"))
    let package = directory.appending(path: "Fixture")
    try writeFixturePackage(package, image: catalog.builtIn.front, inputKey: "missing")
    #expect(throws: RemotePackageError.self) { try catalog.install(package) }
    #expect(catalog.models.count == 1)

    try writeFixturePackage(package, image: catalog.builtIn.front, vendor: 0x2717, product: 0x32B8)
    #expect(throws: RemotePackageError.self) { try catalog.install(package) }
    #expect(catalog.models.count == 1)

    try writeFixturePackage(package, image: catalog.builtIn.front)
    _ = try catalog.install(package)
    #expect(throws: RemotePackageError.self) { try catalog.install(package) }
    #expect(catalog.models.map(\.id).sorted() == ["test-remote", RemoteDefinition.xiaomiID])
}

private func writeFixturePackage(_ package: URL, image: URL, vendor: Int = 0x1234, product: Int = 0x5678,
                                 inputKey: String = "play") throws {
    let files = FileManager.default
    try files.createDirectory(at: package, withIntermediateDirectories: true)
    let front = package.appending(path: "front.png")
    if !files.fileExists(atPath: front.path) { try files.copyItem(at: image, to: front) }
    let manifest = """
    {"version":1,"id":"test-remote","name":"双键测试遥控器","devices":[{"vendor":\(vendor),"product":\(product)}],
     "front":"front.png","capabilities":[]}
    """
    let layout = """
    {"width":724,"height":2172,"visible":{"x":100,"y":106,"width":525,"height":700},
     "keys":[{"id":"play","name":"播放","symbol":"play",
              "shape":{"kind":"rectangle","x":0.31,"y":0.18,"width":0.24,"height":0.12}},
             {"id":"stop","name":"停止","symbol":"stop",
              "shape":{"kind":"ellipse","x":0.67,"y":0.25,"width":0.20,"height":0.08}}],"anchors":[]}
    """
    let inputs = """
    [{"key":"\(inputKey)","collectionPage":12,"collectionUsage":1,"page":12,"usage":205,"report":2}]
    """
    for (name, content) in [("manifest", manifest), ("layout", layout), ("inputs", inputs)] {
        try Data(content.utf8).write(to: package.appending(path: "\(name).json"))
    }
}

@Test @MainActor
func versionSixConfigurationPreservesSelectedXiaomiAndItsCalibratedProfile() throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    let signal = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x28, report: 1, value: 1)
    var previous = Configuration()
    previous.version = 6
    previous.selectDevice(device)
    previous.updateRemote { $0.learn(signal, as: "back") }
    let profile = AgentProfile(name: "工作", target: nil, actions: ["back": .showDesktop])
    previous.agents = [profile]
    previous.activeAgentID = profile.id
    let original = try JSONEncoder().encode(previous)
    try original.write(to: storeURL)

    let model = fixtureRemoteModel(hid: InputFixture(devices: [device]), storeURL: storeURL, runAction: { _, _ in })
    #expect(model.unassignedProfiles == [legacyModelProfile(profile)])
    #expect(model.profile?.id == AgentProfile.defaults.id)
    #expect(model.config.selectedDevice == device)
    #expect(model.config.activeRemote?.slot(for: signal) == "back")
    #expect(model.config.version == Configuration.currentVersion)
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v6.backup")) == original)
    #expect(model.assignProfile(profile.id))
    #expect(model.profile?.target == .chatGPT)
    #expect(model.profile?.actions == profile.actions)
}

@Test @MainActor
func gestureDispatchSeparatesTapsAndHoldsAndCancelsPendingWork() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let input = InputFixture(devices: [device])
    input.state = .listening
    input.capturesKeyboard = true
    input.capturedUsages = [0x28]
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var actions: [AgentAction] = []
    var gestureTime: ContinuousClock.Instant?
    let doubleClickDelay: Duration = .milliseconds(300)
    let model = fixtureRemoteModel(hid: input, storeURL: folder.appending(path: "configuration.json"),
                                   doubleClickDelay: doubleClickDelay, gestureNow: { gestureTime ?? .now }) { action, _ in
        actions.append(action)
    }
    model.refreshPermissions()
    model.setAction(.showDesktop, for: "ok")
    model.setAction(.lockScreen, for: "ok-double")
    model.setAction(.toggleDisplays, for: "ok-long")
    model.setAction(.showDesktop, for: "voice-double")
    model.setAction(.showDesktop, for: "minus-long")
    model.setAction(.dictation, for: "ok")
    #expect(model.editableActions["voice-double"] == nil)
    #expect(model.editableActions["minus-long"] == nil)
    #expect(model.editableActions["ok"] == .showDesktop)
    try #require(model.saveConfigurationChanges(as: "手势"))

    let code = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x28, report: 1, value: 1)
    let origin = RemoteInputOrigin(endpoint: 9, cookie: 1)
    func press() {
        input.onEvent(device, .pressed(code, origin: origin))
        #expect(model.pressedHardwareKey == "ok")
    }
    func release() {
        let previousRelease = model.lastKeyRelease
        input.onEvent(device, .released(code, origin: origin))
        #expect(model.pressedHardwareKey == nil)
        #expect(model.lastKeyRelease?.key == "ok")
        #expect(model.lastKeyRelease != previousRelease)
    }
    func tap() { press(); release() }
    func gestureSequence(_ events: () -> Void) {
        // Keep synthetic HID edges together even if the test runner is descheduled.
        gestureTime = .now
        defer { gestureTime = nil }
        events()
    }

    gestureSequence {
        tap()
        #expect(!model.isRunning)
        tap()
    }
    try await waitUntil { actions.count == 1 && !model.isRunning }
    #expect(actions == [.lockScreen])

    gestureSequence { tap() }
    try await waitUntil { actions.count == 2 && !model.isRunning }
    #expect(actions == [.lockScreen, .showDesktop])

    gestureSequence { tap(); press() }
    try await waitUntil { actions.count == 3 && !model.isRunning }
    release()
    #expect(actions == [.lockScreen, .showDesktop, .toggleDisplays])

    gestureSequence {
        tap()
        model.setDiagnosing(true)
        model.setDiagnosing(false)
        tap()
        input.onEvent(device, .endpointClosed(origin.endpoint))
    }
    try await Task.sleep(for: doubleClickDelay + .milliseconds(50))
    #expect(actions.count == 3)

    let previousRelease = model.lastKeyRelease
    press()
    input.onEvent(device, .endpointClosed(origin.endpoint))
    #expect(model.pressedHardwareKey == nil)
    #expect(model.lastKeyRelease == previousRelease)

    // Completing a double-click must not replace the feedback of a newer held key.
    let right = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x4F, report: 1, value: 1)
    gestureSequence {
        tap()
        press()
        input.press(device, right)
        input.onEvent(device, .released(code, origin: origin))
    }
    #expect(model.hardwarePress?.key == "right")
    #expect(model.pressedHardwareKey == "right")
    input.onEvent(device, .released(right))
    #expect(model.pressedHardwareKey == nil)
    #expect(model.lastKeyRelease?.key == "right")
    try await waitUntil { actions.count == 4 && !model.isRunning }
    #expect(actions.last == .lockScreen)
}

@Test @MainActor
func firstRunDetectsDeviceBeforeAuthorizationAndOnlyFinishesWhenReady() {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    var allowPost = false
    var allowAccessibility = false
    let model = fixtureRemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                                   permissions: .init(postEvents: { allowPost }, accessibility: { allowAccessibility }),
                                   runAction: { _, _ in })

    model.refreshPermissions()
    let beforeAuthorization = SetupReadiness(model: model)
    #expect(beforeAuthorization.connected)
    #expect(!beforeAuthorization.inputMonitoring)
    #expect(!beforeAuthorization.canFinish)
    #expect(SetupStage.ready.restored(hasModel: true, readiness: beforeAuthorization) == .permissions)

    input.state = .listening
    allowPost = true
    model.refreshPermissions()
    #expect(!SetupReadiness(model: model).canFinish)

    allowAccessibility = true
    input.state = .failed(-1)
    model.refreshPermissions()
    #expect(SetupReadiness(model: model).hasPermissions)
    #expect(!SetupReadiness(model: model).canFinish)
    #expect(SetupStage.permissions.restored(hasModel: true, readiness: SetupReadiness(model: model)) == .permissions)

    input.onMonitorState(.listening)
    #expect(!model.hasVerifiedInput)
    let ready = SetupReadiness(model: model)
    #expect(ready.canFinish)
    #expect(SetupStage.permissions.restored(hasModel: true, readiness: ready) == .ready)
    #expect(SetupStage.ready.restored(hasModel: true, readiness: ready) == .ready)
    #expect(SetupStage.welcome.restored(hasModel: true, readiness: ready) == .welcome)

    input.onAmbiguousDevices([device])
    #expect(!SetupReadiness(model: model).connected)
    #expect(!SetupReadiness(model: model).canFinish)

    input.onDevices([])
    let disconnected = SetupReadiness(model: model)
    #expect(!disconnected.connected)
    #expect(SetupStage.permissions.restored(hasModel: true, readiness: disconnected) == .permissions)
    #expect(SetupStage.ready.restored(hasModel: true, readiness: disconnected) == .permissions)
    #expect(SetupStage.permissions.restored(hasModel: false, readiness: disconnected) == .remote)
}

@Test @MainActor
func replacingTheSelectedRemoteKeepsAppAuthorization() throws {
    let first = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote", serial: "first")
    let second = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote", serial: "second")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = directory.appending(path: "configuration.json")
    let input = InputFixture(devices: [first])
    input.state = .listening
    let model = fixtureRemoteModel(hid: input, storeURL: store,
                                   permissions: .init(postEvents: { true }, accessibility: { true }, listenEvents: { true }),
                                   runAction: { _, _ in })

    model.refreshPermissions()
    #expect(model.connectedDevice == first)
    input.onDevices([])
    #expect(!model.connected)
    #expect(SetupReadiness(model: model).hasPermissions)

    input.onDevices([second])
    #expect(model.connectedDevice == second)
    #expect(input.selectedDevice == second)
    #expect(SetupReadiness(model: model).canFinish)
    #expect(model.requestedPermission == nil)
    let persisted = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: store))
    #expect(persisted.selectedDevice == second)
}
