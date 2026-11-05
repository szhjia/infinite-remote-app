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
func hardwareListenerChangesUpdateReadinessWithoutRefreshingPermissions() {
    let remote = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [remote])
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })

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
    old.selectDevice(device)
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

    let model = RemoteModel(hid: InputFixture(devices: [device]), storeURL: storeURL, runAction: { _, _ in })
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storeURL))
    #expect(saved == model.config)
    #expect(saved.version == Configuration.currentVersion)
    #expect(saved.activeAgentID == "codex")
    #expect(saved.remotes == old.remotes)
    #expect(saved.agents.count == 1)
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v1.backup")) == original)

    let codex = try #require(saved.activeAgent)
    #expect(codex.name == "ChatGPT")
    #expect(codex.actions["menu"] == .appleMenu)
    #expect(codex.actions["power"] == .displaySleep)
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
        RemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    }

    #expect(openModel().profile == .defaults)

    var previousPreset = AgentProfile.chatGPT
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
    #expect(migrated.profile == custom)
    #expect(migrated.profiles.contains(AgentProfile.chatGPT))
    #expect(migrated.selectProfile(AgentProfile.chatGPT.id))
    #expect(openModel().editableActions["power-long"] == .lockScreen)

    migrated.setAction(nil, for: "power-long")
    #expect(migrated.saveConfigurationChanges())
    #expect(openModel().profile == previousPreset)
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
    let model = RemoteModel(hid: input, storeURL: storeURL, runAction: runAction)
    #expect(try Data(contentsOf: storeURL.appendingPathExtension("v3.backup")) == original)
    #expect(model.profiles.first == AgentProfile.defaults)

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
    let reopened = RemoteModel(hid: reopenedInput, storeURL: storeURL, runAction: runAction)
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
func liveRemoteOnlyEnablesVirtualButtonsForTheSelectedOnlineXiaomi() {
    let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let other = DeviceID(vendor: 1, product: 2, name: "通用遥控器")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [xiaomi, other])
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })
    model.refreshPermissions()
    #expect(model.connectedDevice == xiaomi)
    #expect(model.hasConnectedXiaomi)
    #expect(!model.canReadKeys)
    input.onDevices([other])
    #expect(model.connectedDevice == nil)
    #expect(!model.hasConnectedXiaomi)

    model.selectDevice(other)
    #expect(model.connectedDevice == nil)
    #expect(!model.hasConnectedXiaomi)
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
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
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
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            powerHoldDelay: .milliseconds(50)) { action, _ in dispatched.append(action) }
    model.refreshPermissions()
    model.selectSlot("power")
    model.startLearning()
    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .released(code, origin: origin))
    #expect(model.saveConfigurationChanges())

    input.onEvent(device, .pressed(code, origin: origin))
    #expect(dispatched.isEmpty)
    input.onEvent(device, .released(code, origin: origin))
    try await waitForAction(on: model)
    #expect(dispatched == [.displaySleep])

    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .pressed(code, origin: origin))
    try await waitUntil { dispatched.count == 2 && !model.isRunning }
    input.onEvent(device, .released(code, origin: origin))
    #expect(dispatched == [.displaySleep, .lockScreen])

    input.onEvent(device, .pressed(code, origin: origin))
    model.isEnabled = false
    model.isEnabled = true
    input.onEvent(device, .released(code, origin: origin))
    input.onEvent(device, .pressed(code, origin: origin))
    input.onEvent(device, .endpointClosed(origin.endpoint))
    try await Task.sleep(for: .milliseconds(80))
    #expect(dispatched == [.displaySleep, .lockScreen])
}

@Test @MainActor
func namedProfilesAndImportsCannotOverwriteTheBuiltInOrLoseDrafts() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    let model = RemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    model.setAction(.appleMenu, for: "menu")
    #expect(!model.saveConfigurationChanges())
    #expect(!model.saveConfigurationChanges(as: " 默认配置 "))
    #expect(model.profile == AgentProfile.defaults)
    #expect(model.saveConfigurationChanges(as: " Café "))
    let saved = try #require(model.profile)
    let file = directory.appending(path: "profile.json")
    try ProfileArchive(saved).write(to: file)
    let archive = try ProfileArchive.read(from: file)
    #expect(!model.importProfile(archive, as: "cafe\u{301}", discardingDraft: false))
    model.restoreDefaultActions()
    #expect(!model.selectProfile(AgentProfile.defaults.id))
    #expect(!model.importProfile(archive, as: "备份", discardingDraft: false))
    #expect(model.hasConfigurationChanges)
    #expect(model.importProfile(archive, as: "备份", discardingDraft: true))
    let reopened = RemoteModel(hid: InputFixture(devices: []), storeURL: storeURL, runAction: { _, _ in })
    #expect(reopened.profiles.map(\.name) == ["默认配置", "Café", "备份"])
    #expect(reopened.profile?.actions["menu"] == .appleMenu)
    #expect(reopened.profiles.first == AgentProfile.defaults)
}

@Test @MainActor
func xiaomiButtonsWorkWithoutLearningAndUseTheSavedAction() async throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched: [AgentAction] = []
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
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
    press(0x4A)
    #expect(openedSwitcher)

    model.setAction(.showDesktop, for: "plus")
    #expect(model.hasConfigurationChanges)
    #expect(model.saveConfigurationChanges(as: "自定义"))
    press(0x80)
    try await waitForAction(on: model)
    #expect(dispatched == [.volumeUp, .volumeDown, .showDesktop])
    #expect(model.editableRemote?.keys.isEmpty == true)
}

@Test @MainActor
func xiaomiHomeAliasesToggleAppSwitcherOncePerPhysicalPress() {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let array = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                          usage: Int(UInt32.max), report: 1, value: 0x4A)
    let direct = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                           usage: 0x4A, report: 1, value: 1)
    let arrayOrigin = RemoteInputOrigin(endpoint: 8, cookie: 1)
    let directOrigin = RemoteInputOrigin(endpoint: 8, cookie: 2)
    let input = InputFixture(devices: [device])
    input.state = .listening
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            runAction: { _, _ in })
    model.refreshPermissions()
    var visible = false
    var toggles = 0
    model.onSwitchApps = { visible = true; toggles += 1 }
    model.onMediaKey = { slot, _ in
        guard visible, slot == "home" else { return false }
        visible = false
        toggles += 1
        return true
    }

    input.onEvent(device, .pressed(array, origin: arrayOrigin))
    input.onEvent(device, .pressed(direct, origin: directOrigin))
    #expect(visible)
    #expect(toggles == 1)
    input.onEvent(device, .released(array, origin: arrayOrigin))
    input.onEvent(device, .released(direct, origin: directOrigin))

    input.onEvent(device, .pressed(direct, origin: directOrigin))
    input.onEvent(device, .pressed(array, origin: arrayOrigin))
    #expect(!visible)
    #expect(toggles == 2)
}

@Test @MainActor
func mediaAndRunningAppChoosersConsumeNavigationBeforeConfiguredActions() throws {
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米 2 Pro")
    let tv = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x61, report: 1, value: 1)
    let right = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x42, report: 1, value: 1)
    let home = InputCode(collectionPage: 12, collectionUsage: 1, page: 12, usage: 0x45, report: 1, value: 1)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = InputFixture(devices: [device])
    input.state = .listening
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json")) { action, _ in
        Issue.record("Unexpected action while selecting media: \(action)")
    }
    model.refreshPermissions()
    for (slot, code) in [("tv", tv), ("right", right), ("home", home)] {
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
    input.press(device, home)
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
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            dictation: dictation, runAction: { _, _ in })
    model.refreshPermissions()
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
    #expect(model.activity.contains { $0.text.hasPrefix("松开 · 语音") })
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
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
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
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            dictation: dictation, runAction: { _, _ in })
    model.refreshPermissions()
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
private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition() && clock.now < deadline {
        try await clock.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}
