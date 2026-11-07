import Foundation
import RemoteCore
import Testing
@testable import RemoteDesk

@MainActor
private final class RoutingFixture: RemoteInputSource {
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onMonitorState: (InputMonitorState) -> Void = { _ in }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void = { _, _ in }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void = { _ in }
    var selectedDevice: DeviceID?
    var captured = true
    var preservesNativeF5 = false
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Test 2 Pro")
    let origin = RemoteInputOrigin(endpoint: 3, cookie: 4)
    var focus = ForegroundContext(bundleID: AppTarget.finder.bundleID, pid: 11)
    var executed: [(AgentAction, String?)] = []
    var voice: [(KeyboardShortcut, Bool)] = []

    func refresh() -> InputMonitorState {
        onDevices([device])
        return .listening
    }

    func captures(_ input: InputCode, from source: RemoteInputOrigin?) -> Bool {
        captured && source == origin && !(preservesNativeF5 && input.isKeyboardF5)
    }

    func send(_ usage: Int, down: Bool) {
        let code = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: usage, report: 1, value: 1)
        onEvent(device, down ? .pressed(code, origin: origin) : .released(code, origin: origin))
    }

    func tap(_ usage: Int) {
        send(usage, down: true)
        send(usage, down: false)
    }

    func model(in folder: URL, finderViewSupported: Bool = true, isChatGPTEnabled: Bool = true) -> RemoteModel {
        _ = fixtureCatalog(directory: folder.appending(path: "RemoteModels"))
        let model = RemoteModel(hid: self, storeURL: folder.appending(path: "configuration.json"),
                                permissions: .init(postEvents: { true }, accessibility: { true }),
                                powerHoldDelay: .milliseconds(45), doubleClickDelay: .milliseconds(60),
                                foreground: { self.focus },
                                isChatGPTEnabled: isChatGPTEnabled,
                                finderSupportsNavigation: { _ in finderViewSupported },
                                postVoice: { self.voice.append(($0, $1)) },
                                runAction: { self.executed.append(($0, $1?.bundleID)) })
        model.refreshPermissions()
        return model
    }
}

@Test @MainActor
func finderBackSendsEscapeEvenWhenAMenuObscuresTheBrowserView() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder, finderViewSupported: false)

    #expect(model.editableActions["back"] == .finder(.escape))
    fixture.tap(0xF1)
    await waitForRouting { fixture.executed.count == 1 }
    #expect(fixture.executed.map(\.0) == [.finder(.escape)])
    #expect(fixture.executed.first?.1 == AppTarget.finder.bundleID)
}

@Test @MainActor
func foregroundRoutingIsIndependentFromEditingAndIgnoresUnverifiedNativeGestures() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    let other = AppTarget(bundleID: "example.editor")
    let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.command], keyName: "R")
    #expect(model.apps.prefix(2).map(\.bundleID) == [AppTarget.finder.bundleID, AppTarget.chatGPT.bundleID])
    #expect(model.addApp(other))
    model.setAction(.shortcut(shortcut), for: "ok")
    #expect(model.saveConfigurationChanges(as: "Editor"))

    fixture.tap(0x28)
    fixture.tap(0x28)
    await waitForRouting { fixture.executed.count == 1 }
    #expect(fixture.executed.map(\.0) == [.finder(.contextMenu)])
    #expect(fixture.executed.first?.1 == AppTarget.finder.bundleID)

    fixture.captured = false
    fixture.tap(0x28)
    fixture.tap(0x28)
    #expect(model.feedback == L10n.tr("当前设备无法可靠改绑，已保留原生按键。"))
    try await Task.sleep(for: .milliseconds(80))
    #expect(fixture.executed.count == 1)

    fixture.captured = true
    fixture.tap(0x28) // pending Finder single
    fixture.focus = .init(bundleID: other.bundleID, pid: 12)
    model.foregroundChanged()
    fixture.tap(0x28)
    await waitForRouting { fixture.executed.count == 2 }
    try await Task.sleep(for: .milliseconds(80))
    #expect(fixture.executed.map(\.0) == [.finder(.contextMenu), .shortcut(shortcut)])
    #expect(fixture.executed.last?.1 == other.bundleID)

    fixture.focus = .init(bundleID: "example.unconfigured", pid: 13)
    fixture.tap(0x4A)
    await waitForRouting { fixture.executed.count == 3 }
    #expect(fixture.executed.last?.0 == .openFinder)
    #expect(fixture.executed.last?.1 == nil)
    let reopened = fixture.model(in: folder)
    #expect(reopened.addApp(other))
    #expect(reopened.profile?.actions["ok"] == .shortcut(shortcut))
    #expect(reopened.apps.filter { $0.bundleID == other.bundleID }.count == 1)
}

@Test @MainActor
func chatGPTUsesNativeF5UntilAnAppVoiceBindingIsSaved() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option], keyName: "C")
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    model.foregroundChanged()
    #expect(fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.voice.isEmpty)
    #expect(model.feedback == L10n.tr("已保留原生 F5，请在 ChatGPT 确认听写。"))

    model.selectEditingApp(.chatGPT)
    model.setAction(.voiceShortcut(.macOS, shortcut), for: "voice")
    #expect(fixture.preservesNativeF5)
    #expect(model.saveConfigurationChanges(as: "ChatGPT System Dictation"))
    #expect(!fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.voice.map(\.1) == [true, false])
    #expect(fixture.voice.allSatisfy { $0.0 == shortcut })
}

@Test @MainActor
func generalVoiceWorksInChatGPTUntilAnExplicitChatGPTBindingTakesPrecedence() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option], keyName: "C")
    #expect(!model.setDefaultVoice(.voiceShortcut(.weType, shortcut)))
    try #require(model.setDefaultVoice(.voiceShortcut(.macOS, shortcut)))
    fixture.tap(0x3E)
    #expect(fixture.voice.map(\.1) == [true, false])
    #expect(fixture.voice.allSatisfy { $0.0 == shortcut })

    fixture.captured = false
    fixture.tap(0x3E)
    #expect(fixture.voice.count == 2)
    fixture.captured = true
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    model.foregroundChanged()
    #expect(!fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.voice.map(\.1) == [true, false, true, false])

    model.selectEditingApp(.chatGPT)
    model.setAction(.chatGPTDraft, for: "voice")
    try #require(model.saveConfigurationChanges(as: "ChatGPT Dictation"))
    #expect(fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.voice.count == 4)

    let disabled = fixture.model(in: folder, isChatGPTEnabled: false)
    disabled.selectEditingApp(.chatGPT)
    #expect(disabled.editableActions["voice"] == .chatGPTDraft)
    #expect(!fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.voice.map(\.1) == [true, false, true, false, true, false])
    #expect(fixture.voice.allSatisfy { $0.0 == shortcut })
}

@Test @MainActor
func upgradeRemovesOnlyWeTypeBindingsAndKeepsOriginalConfigAsBackup() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let shortcut = KeyboardShortcut(keyCode: 40, modifiers: [.control, .option], keyName: "K")
    let modelID = "xiaomi-2-pro"
    let profile = AgentProfile(name: "Finder", target: .finder,
                               actions: ["voice": .voiceShortcut(.weType, shortcut), "ok": .finder(.open)],
                               modelID: modelID)
    var legacy = Configuration()
    legacy.version = 10
    legacy.selectedModelID = modelID
    legacy.agents = [profile]
    legacy.defaultVoiceByModel = [modelID: .voiceShortcut(.weType, shortcut),
                                  "other-model": .voiceShortcut(.macOS, shortcut)]
    legacy.selectProfile(profile.id, modelID: modelID, bundleID: AppTarget.finder.bundleID)
    let original = try JSONEncoder().encode(legacy)
    let url = folder.appending(path: "configuration.json")
    try original.write(to: url)
    let model = RoutingFixture().model(in: folder)
    #expect(model.config.version == Configuration.currentVersion)
    #expect(model.config.agents.first?.actions == ["ok": .finder(.open)])
    #expect(model.config.activeProfileID(modelID: modelID, bundleID: AppTarget.finder.bundleID) == profile.id)
    #expect(model.config.defaultVoiceByModel == ["other-model": .voiceShortcut(.macOS, shortcut)])
    #expect(try Data(contentsOf: url.appendingPathExtension("v10.backup")) == original)
    let persisted = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    #expect(persisted == model.config)
}

@Test @MainActor
func finderHoldRepeatsWithoutEmittingTapAndStopsOnRelease() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    fixture.send(0x52, down: true)
    await waitForRouting { fixture.executed.count >= 2 }
    fixture.send(0x52, down: false)
    let before = fixture.executed.count
    try await Task.sleep(for: .milliseconds(180))
    #expect(fixture.executed.count == before)
    #expect(fixture.executed.allSatisfy { $0.0 == .finder(.up) })
    #expect(model.hardwarePress?.phase == .longPress)
}

@Test @MainActor
func globalHomeClosesTheChooserAndDeduplicatesAliasReports() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    var chooserClosed = 0
    model.onDismissMedia = { chooserClosed += 1 }
    model.onMediaKey = { _, _ in
        Issue.record("The chooser must not consume Home")
        return true
    }
    let array = InputCode(collectionPage: 1, collectionUsage: 6, page: 7,
                          usage: Int(UInt32.max), report: 1, value: 0x4A)
    fixture.send(0x4A, down: true)
    fixture.onEvent(fixture.device, .pressed(array, origin: .init(endpoint: 3, cookie: 5)))
    await waitForRouting { fixture.executed.count == 1 }
    #expect(chooserClosed == 1)
    #expect(fixture.executed.map(\.0) == [.openFinder])
}

@Test @MainActor
func deviceMapCoversOnlyKnownRemoteKeyboardUsages() {
    func input(_ page: Int, _ usage: Int, _ value: Int) -> InputCode {
        InputCode(collectionPage: 1, collectionUsage: 6, page: page, usage: usage, report: 1, value: value)
    }
    #expect(RemoteKeyboardMap.covers(input(7, 0x3E, 1)))
    #expect(!RemoteKeyboardMap.covers(input(7, 0x3E, 1), preservingNativeF5: true))
    #expect(!RemoteKeyboardMap.covers(input(7, Int(UInt32.max), 0x3E), preservingNativeF5: true))
    #expect(RemoteKeyboardMap.covers(input(7, 0x51, 1), preservingNativeF5: true))
    #expect(RemoteKeyboardMap.covers(input(7, Int(UInt32.max), 0x28)))
    #expect(!RemoteKeyboardMap.covers(input(7, 0x04, 1)))
    #expect(!RemoteKeyboardMap.covers(input(12, 0xE9, 1)))
}

@MainActor
private func waitForRouting(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test(arguments: [1, 2]) @MainActor
func legacyChatGPTArchiveKeepsItsOriginalTarget(version: Int) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    let url = folder.appending(path: "legacy.json")
    let shortcut = AgentAction.shortcut(AgentProfile.newChat)
    let actions = try JSONEncoder().encode(["ok": shortcut])
    let modelField = version == 2 ? "\"modelID\":\"xiaomi-2-pro\"," : ""
    let oldArchive = """
    {"version":\(version),\(modelField)"name":"My ChatGPT","actions":\(String(decoding: actions, as: UTF8.self))}
    """
    try Data(oldArchive.utf8).write(to: url)
    try #require(model.editingApp == .finder)
    try #require(model.importProfile(try ProfileArchive.read(from: url), as: "My ChatGPT", discardingDraft: false))
    #expect(model.profile?.target?.bundleID == AppTarget.chatGPT.bundleID)
}

@Test @MainActor
func uncapturedCalibratedArrowDoesNotEmitSecondKey() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: "example.unconfigured", pid: 13)
    let model = fixture.model(in: folder)
    fixture.captured = false
    model.selectSlot("right")
    model.startLearning()
    fixture.tap(0x50)
    try #require(model.calibrationConflict != nil)
    model.resolveCalibrationConflict(transfer: true)
    try #require(model.saveConfigurationChanges())
    fixture.tap(0x50)
    try await Task.sleep(for: .milliseconds(120))
    #expect(fixture.executed.isEmpty)

    fixture.captured = true
    fixture.tap(0x50)
    await waitForRouting { !fixture.executed.isEmpty }
    #expect(fixture.executed.map(\.0) == [AgentProfile.defaults.actions["right"]])
}

@Test @MainActor
func remappedVoiceButtonDoesNotAuthorizeMicrophoneStream() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let model = fixture.model(in: folder)
    model.toggleRemoteMicrophone()
    model.selectSlot("right")
    model.startLearning()
    fixture.tap(0x3E)
    try #require(model.calibrationConflict != nil)
    model.resolveCalibrationConflict(transfer: true)
    try #require(model.saveConfigurationChanges())
    try #require(!fixture.preservesNativeF5)
    fixture.send(0x3E, down: true)
    defer { fixture.send(0x3E, down: false) }
    await waitForRouting { !fixture.executed.isEmpty }
    try #require(fixture.executed.first?.0 == AgentProfile.defaults.actions["right"])
    try #require(fixture.voice.isEmpty)
    #expect(!model.remoteMicrophone.canStream())
}

@Test @MainActor
func onlyAnAcceptedPhysicalVoicePressAuthorizesAudioUntilReleaseOrInterruption() {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let model = fixture.model(in: folder)
    model.toggleRemoteMicrophone()
    let microphone = model.remoteMicrophone
    #expect(microphone.status == L10n.tr("无法确认所选遥控器的蓝牙身份。"))
    #expect(!microphone.canStream())

    fixture.send(0x3E, down: true)
    #expect(microphone.canStream())
    #expect(fixture.voice.isEmpty)
    fixture.send(0x50, down: false)
    #expect(microphone.canStream())
    fixture.send(0x3E, down: false)
    #expect(!microphone.canStream())

    fixture.send(0x3E, down: true)
    fixture.onEvent(fixture.device, .endpointClosed(fixture.origin.endpoint))
    #expect(!microphone.canStream())

    fixture.send(0x3E, down: true)
    fixture.focus = .init(bundleID: "example.editor", pid: 15)
    #expect(!microphone.canStream())
    model.foregroundChanged()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    #expect(!microphone.canStream())
}
