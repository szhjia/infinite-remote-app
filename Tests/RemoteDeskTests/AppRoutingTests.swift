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
    var onKeyboardCapture: (Bool) -> Void = { _ in }
    var selectedDevice: DeviceID?
    var captured = true
    var preservesNativeF5 = false
    var accessibilityAllowed = true
    let device = DeviceID(vendor: 0x2717, product: 0x32B8, name: "Test 2 Pro")
    let origin = RemoteInputOrigin(endpoint: 3, cookie: 4)
    var focus = ForegroundContext(bundleID: AppTarget.finder.bundleID, pid: 11)
    var executed: [(AgentAction, String?)] = []
    private var gestureTime: ContinuousClock.Instant?
    var voice: [(KeyboardShortcut, Bool)] = []
    var systemDictationTargets: [Int32] = []
    var systemDictationFailure: SystemDictation.Failure?
    var microphoneBluetoothAuthorized = true
    var microphoneLoopbackAvailable = true

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
        let previous = gestureTime
        gestureTime = previous ?? .now
        defer { gestureTime = previous }
        send(usage, down: true)
        send(usage, down: false)
    }

    func doubleTap(_ usage: Int) {
        gestureTime = .now
        defer { gestureTime = nil }
        tap(usage)
        tap(usage)
    }

    func model(in folder: URL, finderViewSupported: Bool = true, isChatGPTEnabled: Bool = true,
               powerHoldDelay: Duration = .milliseconds(45), doubleClickDelay: Duration = .milliseconds(60),
               codexAccess: CodexConversationControl.Access = .system) -> RemoteModel {
        seedInstalledLegacyModel(in: folder.appending(path: "RemoteModels"))
        let model = RemoteModel(hid: self, storeURL: folder.appending(path: "configuration.json"),
                                permissions: .init(postEvents: { true }, accessibility: { self.accessibilityAllowed }),
                                powerHoldDelay: powerHoldDelay, doubleClickDelay: doubleClickDelay,
                                gestureNow: { self.gestureTime ?? .now },
                                foreground: { self.focus },
                                isChatGPTEnabled: isChatGPTEnabled,
                                finderSupportsNavigation: { _ in finderViewSupported },
                                startSystemDictation: { context in
                                    self.systemDictationTargets.append(context.pid)
                                    if let failure = self.systemDictationFailure { throw failure }
                                },
                                postVoice: { self.voice.append(($0, $1)) },
                                microphoneRequirements: .init(bluetoothAuthorized: { self.microphoneBluetoothAuthorized },
                                                              loopbackAvailable: { self.microphoneLoopbackAvailable }),
                                codexAccess: codexAccess,
                                runAction: { self.executed.append(($0, $1?.bundleID)) })
        model.refreshPermissions()
        return model
    }
}

@Test @MainActor
func codexPresetIsOptInAndUsesNativeF5AndOnlyTheDedicatedSendControl() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let session = CodexConversationFixture()
    let access = CodexConversationControl.Access(session: { _ in session }, scroll: { _, _ in nil })
    let model = fixture.model(in: folder, codexAccess: access)
    model.selectEditingApp(.chatGPT)
    let preset = try #require(model.profiles.first(where: model.isCodexPreset))
    #expect(model.profile?.id == AgentProfile.defaults.id)
    #expect(preset.actions["ok"] == .codexConversation(.sendTranscript))
    try #require(model.selectProfile(preset.id))
    #expect(fixture.preservesNativeF5)
    model.setAction(.shortcut(AgentProfile.sendDraft), for: "ok")
    #expect(!model.hasConfigurationChanges)

    fixture.send(0x3E, down: true)
    let baselineReads = session.reads
    try #require(baselineReads == 1, "Voice down must observe the empty composer")
    session.observation = .recording
    await waitForRouting(timeout: .seconds(10)) { session.reads > baselineReads }
    try #require(session.reads > baselineReads, "The recording must be observed before release")
    session.observation = .transcribing
    fixture.send(0x3E, down: false)
    fixture.tap(0x28)
    #expect(session.sent.isEmpty)
    session.observation = .ready("Only this transcript")
    model.pressVirtualKey("ok")
    #expect(session.sent.isEmpty)
    fixture.tap(0x28)
    fixture.tap(0x28)
    #expect(session.sent == ["Only this transcript"])
    #expect(fixture.executed.isEmpty)
    #expect(fixture.voice.isEmpty)

    let reopened = fixture.model(in: folder, codexAccess: access)
    reopened.selectEditingApp(.chatGPT)
    #expect(reopened.profile?.id == preset.id)
    reopened.selectEditingApp(.finder)
    #expect(!reopened.profiles.contains(where: reopened.isCodexPreset))
}

@Test(arguments: ["return", "same-window conversation change", "approval", "pause", "capture lost",
                  "uncaptured center", "endpoint closed", "disconnect"])
@MainActor
func codexPresetCancelsDraftWithoutSynthesizingEnterOrEscape(_ interruption: String) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let session = CodexConversationFixture()
    let model = fixture.model(in: folder, codexAccess: .init(session: { _ in session }, scroll: { _, _ in nil }))
    model.selectEditingApp(.chatGPT)
    let preset = try #require(model.profiles.first(where: model.isCodexPreset))
    try #require(model.selectProfile(preset.id))
    fixture.send(0x3E, down: true)
    let baselineReads = session.reads
    try #require(baselineReads == 1)
    session.observation = .recording
    await waitForRouting(timeout: .seconds(10)) { session.reads > baselineReads }
    try #require(session.reads > baselineReads)
    session.observation = .transcribing
    fixture.send(0x3E, down: false)
    session.observation = .ready("Draft")
    let releasedReads = session.reads
    await waitForRouting(timeout: .seconds(10)) { session.reads > releasedReads }
    try #require(session.reads > releasedReads)

    switch interruption {
    case "return": fixture.tap(0xF1)
    case "same-window conversation change", "approval":
        session.observation = nil // AX cannot confirm the same usable composer anymore.
        let armedReads = session.reads
        await waitForRouting(timeout: .seconds(10)) { session.reads > armedReads }
        try #require(session.reads > armedReads)
        session.observation = .ready("Draft")
    case "pause":
        model.isEnabled = false
        model.isEnabled = true
    case "capture lost": fixture.onKeyboardCapture(false)
    case "uncaptured center": fixture.captured = false
    case "endpoint closed": fixture.onEvent(fixture.device, .endpointClosed(fixture.origin.endpoint))
    case "disconnect":
        fixture.onDevices([])
        fixture.onDevices([fixture.device])
    default: Issue.record("Missing interruption")
    }

    fixture.tap(0x28)
    #expect(session.sent.isEmpty)
    #expect(fixture.executed.isEmpty)
    #expect(fixture.voice.isEmpty)
    if interruption == "uncaptured center" {
        #expect(model.feedback == L10n.tr("无法接管遥控器按键，macOS 仍可能收到原生按键。"))
    }
}

@Test(arguments: [false, true]) @MainActor
func chatGPTScrollsImmediatelyRepeatsWhileHeldAndDoesNotLeakIntoOtherApps(experimental: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    var scrolled: [CodexConversationCommand] = []
    let access = CodexConversationControl.Access(session: { _ in nil }, scroll: { _, command in
        { scrolled.append(command); return true }
    })
    let model = fixture.model(in: folder, codexAccess: access)
    model.selectEditingApp(.chatGPT)
    if experimental {
        let preset = try #require(model.profiles.first(where: model.isCodexPreset))
        try #require(model.selectProfile(preset.id))
    }
    fixture.send(0x52, down: true)
    #expect(scrolled == [.scrollUp])
    await waitForRouting { scrolled.count >= 2 }
    fixture.send(0x52, down: false)
    let afterRelease = scrolled.count
    try await Task.sleep(for: .milliseconds(170))
    #expect(scrolled.count == afterRelease)
    fixture.tap(0x51)
    #expect(scrolled.last == .scrollDown)

    fixture.focus = .init(bundleID: "com.tencent.xinWeChat", pid: 15)
    model.foregroundChanged()
    fixture.tap(0x28)
    await waitForRouting { fixture.executed.count == 1 }
    #expect(fixture.executed.first?.0 == AgentProfile.defaults.actions["ok"])
    #expect(fixture.executed.first?.1 == "com.tencent.xinWeChat")
    #expect(scrolled.count == afterRelease + 1)
}

@Test(arguments: [false, true]) @MainActor
func defaultChatGPTKeepsNativeF5AndDeliversPlainReturnOnce(captured: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    fixture.captured = captured
    let model = fixture.model(in: folder, codexAccess: .init(session: { _ in
        Issue.record("The default profile should leave dictation to ChatGPT")
        return nil
    }, scroll: { _, _ in nil }))
    model.selectEditingApp(.chatGPT)
    #expect(fixture.preservesNativeF5)
    fixture.tap(0x3E)
    fixture.tap(0x28)
    if captured {
        await waitForRouting { fixture.executed.count == 1 }
        #expect(fixture.executed.first?.0 == .foregroundKey(.init(keyCode: 36, modifiers: [], keyName: "Return")))
        #expect(fixture.executed.first?.1 == AppTarget.chatGPT.bundleID)
    } else {
        await Task.yield()
        #expect(fixture.executed.isEmpty)
    }
    #expect(fixture.voice.isEmpty)
}

@Test @MainActor
func chatGPTScrollingSurvivesSavingACustomProfileAndLeavesOtherGesturesAvailable() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    var scrolled: [CodexConversationCommand] = []
    let access = CodexConversationControl.Access(session: { _ in nil }, scroll: { _, command in
        { scrolled.append(command); return true }
    })
    let model = fixture.model(in: folder, codexAccess: access)
    model.selectEditingApp(.chatGPT)
    model.setAction(.shortcut(AgentProfile.newChat), for: "up-double")
    try #require(model.saveConfigurationChanges(as: "ChatGPT with double tap"))

    let reopened = fixture.model(in: folder, codexAccess: access)
    reopened.selectEditingApp(.chatGPT)
    #expect(reopened.profile?.name == "ChatGPT with double tap")
    fixture.tap(0x52)
    await waitForRouting(timeout: .seconds(10)) { !scrolled.isEmpty }
    try #require(scrolled == [.scrollUp])
    fixture.doubleTap(0x52)
    await waitForRouting(timeout: .seconds(10)) { fixture.executed.count == 1 }
    #expect(fixture.executed.first?.0 == .shortcut(AgentProfile.newChat))
    #expect(scrolled == [.scrollUp])
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
    // This scenario exercises routing across real model lookups and saves. Use the
    // production gesture window so machine speed does not turn a tap into a hold.
    let doubleClickDelay: Duration = .milliseconds(300)
    let model = fixture.model(in: folder, powerHoldDelay: .milliseconds(600), doubleClickDelay: doubleClickDelay)
    let other = AppTarget(bundleID: "example.editor")
    let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.command], keyName: "R")
    #expect(model.apps.prefix(2).map(\.bundleID) == [AppTarget.finder.bundleID, AppTarget.chatGPT.bundleID])
    #expect(model.addApp(other))
    model.setAction(.shortcut(shortcut), for: "ok")
    #expect(model.saveConfigurationChanges(as: "Editor"))

    fixture.doubleTap(0x28)
    await waitForRouting { fixture.executed.count == 1 }
    #expect(fixture.executed.map(\.0) == [.finder(.contextMenu)])
    #expect(fixture.executed.first?.1 == AppTarget.finder.bundleID)

    fixture.captured = false
    fixture.doubleTap(0x28)
    #expect(model.feedback == L10n.tr("当前设备无法可靠改绑，已保留原生按键。"))
    try await Task.sleep(for: doubleClickDelay + .milliseconds(50))
    #expect(fixture.executed.count == 1)

    fixture.captured = true
    fixture.tap(0x28) // pending Finder single
    fixture.focus = .init(bundleID: other.bundleID, pid: 12)
    model.foregroundChanged()
    fixture.tap(0x28)
    await waitForRouting { fixture.executed.count == 2 }
    try await Task.sleep(for: doubleClickDelay + .milliseconds(50))
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
func anUnconfiguredVoiceKeyStartsSystemDictationOnceInTheForegroundApp() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: "example.editor", pid: 12)
    let model = fixture.model(in: folder)
    #expect(model.defaultVoice == .systemDictation)
    #expect(model.config.defaultVoiceByModel == nil)
    fixture.send(0x3E, down: true)
    #expect(fixture.systemDictationTargets == [12])
    fixture.send(0x3E, down: false)
    #expect(fixture.systemDictationTargets == [12])
    #expect(fixture.voice.isEmpty)
    #expect(model.error == nil)
}

@Test @MainActor
func systemDictationHonorsCaptureAndPermissionAndDoesNotFallBackToKeyEvents() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    fixture.captured = false
    fixture.tap(0x3E)
    #expect(fixture.systemDictationTargets.isEmpty)
    fixture.captured = true
    fixture.accessibilityAllowed = false
    model.refreshPermissions()
    fixture.tap(0x3E)
    #expect(model.requestedPermission == .accessibility)
    #expect(fixture.systemDictationTargets.isEmpty)
    fixture.accessibilityAllowed = true
    model.refreshPermissions()
    fixture.systemDictationFailure = .unavailable
    fixture.tap(0x3E)
    #expect(fixture.systemDictationTargets == [11])
    #expect(model.error == SystemDictation.Failure.unavailable.localizedDescription)
    #expect(fixture.voice.isEmpty)
}

@Test @MainActor
func explicitSystemDictationBindingSurvivesDisabledDefaultAndReopen() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    try #require(model.setDefaultVoice(nil))
    model.selectEditingApp(.chatGPT)
    model.setAction(.systemDictation, for: "voice")
    try #require(model.saveConfigurationChanges(as: "System Dictation"))

    let reopened = fixture.model(in: folder)
    #expect(reopened.defaultVoice == nil)
    fixture.tap(0x3E)
    #expect(fixture.systemDictationTargets.isEmpty)
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    reopened.foregroundChanged()
    #expect(!fixture.preservesNativeF5)
    fixture.tap(0x3E)
    #expect(fixture.systemDictationTargets == [14])
    #expect(fixture.voice.isEmpty)
}

@Test @MainActor
func legacyClearedDefaultRemainsOffUntilSystemDictationIsSelected() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "configuration.json")
    var legacy = Configuration()
    legacy.version = 11
    legacy.defaultVoiceByModel = [:]
    let original = try JSONEncoder().encode(legacy)
    try original.write(to: url)

    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    #expect(model.defaultVoice == nil)
    #expect(try Data(contentsOf: url.appendingPathExtension("v11.backup")) == original)
    try #require(model.setDefaultVoice(.systemDictation))
    let reopened = fixture.model(in: folder)
    #expect(reopened.defaultVoice == .systemDictation)
    fixture.tap(0x3E)
    #expect(fixture.systemDictationTargets == [11])
    #expect(fixture.voice.isEmpty)
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
    #expect(fixture.systemDictationTargets.isEmpty)
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
func replacingDictationShortcutsKeepsDefaultAndAppBindingsIndependent() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    let model = fixture.model(in: folder)
    let original = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option], keyName: "C")
    let revisedDefault = KeyboardShortcut(keyCode: 40, modifiers: [.control, .option], keyName: "K")
    let revisedFinder = KeyboardShortcut(keyCode: 37, modifiers: [.control, .option], keyName: "L")
    try #require(model.setDefaultVoice(.voiceShortcut(.macOS, original)))
    model.setAction(.voiceShortcut(.macOS, original), for: "voice")
    try #require(model.saveConfigurationChanges(as: "Finder Dictation"))

    try #require(model.setDefaultVoice(.voiceShortcut(.macOS, revisedDefault)))
    #expect(model.editableActions["voice"] == .voiceShortcut(.macOS, original))
    model.setAction(.voiceShortcut(.macOS, revisedFinder), for: "voice")
    try #require(model.saveConfigurationChanges())

    let reopened = fixture.model(in: folder)
    #expect(reopened.defaultVoice == .voiceShortcut(.macOS, revisedDefault))
    #expect(reopened.editableActions["voice"] == .voiceShortcut(.macOS, revisedFinder))
    fixture.tap(0x3E)
    fixture.focus = .init(bundleID: "example.unconfigured", pid: 12)
    reopened.foregroundChanged()
    fixture.tap(0x3E)
    #expect(fixture.voice.map(\.0) == [revisedFinder, revisedFinder, revisedDefault, revisedDefault])
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
    await waitForRouting(timeout: .seconds(10)) { fixture.executed.count >= 2 && !model.isRunning }
    try #require(fixture.executed.count >= 2 && !model.isRunning)
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
private func waitForRouting(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
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

@Test(arguments: [0, 11, Configuration.currentVersion])
@MainActor
func xiaomiMicrophoneDefaultsOnAndRemembersExplicitChoicesAcrossLaunches(_ version: Int) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    if version != 0 {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"version\":\(version),\"activeAgentID\":\"defaults\",\"remotes\":[],\"agents\":[]}".utf8)
            .write(to: folder.appending(path: "configuration.json"))
    }

    let first = RoutingFixture().model(in: folder)
    try #require(first.supportsRemoteMicrophone)
    #expect(first.usesRemoteMicrophone)
    #expect(first.config.remoteMicrophoneEnabledByModel == nil)
    #expect(!first.remoteMicrophone.canStream())

    first.setRemoteMicrophoneEnabled(false)
    #expect(!first.usesRemoteMicrophone)
    let reopened = RoutingFixture().model(in: folder)
    #expect(!reopened.usesRemoteMicrophone)
    #expect(reopened.remoteMicrophoneStatus == L10n.tr("遥控器麦克风未开启。"))
    reopened.setRemoteMicrophoneEnabled(true)
    #expect(RoutingFixture().model(in: folder).usesRemoteMicrophone)
}

@Test @MainActor
func microphoneRecoversAfterReconnectionWithoutReusingTheOldVoicePress() {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let model = fixture.model(in: folder)
    fixture.send(0x3E, down: true)
    #expect(model.remoteMicrophone.canStream())

    fixture.onDevices([])
    #expect(model.usesRemoteMicrophone)
    #expect(model.remoteMicrophoneStatus == L10n.tr("遥控器麦克风未连接。"))
    #expect(!model.remoteMicrophone.canStream())

    fixture.onDevices([fixture.device])
    #expect(model.remoteMicrophoneStatus == L10n.tr("无法确认所选遥控器的蓝牙身份。"))
    #expect(!model.remoteMicrophone.canStream())
    fixture.send(0x3E, down: false)
    fixture.send(0x3E, down: true)
    #expect(model.remoteMicrophone.canStream())
    model.setRemoteMicrophoneEnabled(false)
    #expect(!model.remoteMicrophone.canStream())
}

@Test @MainActor
func enabledMicrophoneReportsMissingPrerequisitesAndRecoversAfterAuthorization() {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    fixture.microphoneLoopbackAvailable = false
    fixture.microphoneBluetoothAuthorized = false
    let model = fixture.model(in: folder)
    #expect(model.usesRemoteMicrophone)
    #expect(model.remoteMicrophoneStatus == L10n.tr("未检测到 BlackHole 2ch，遥控器麦克风尚未连接。"))
    #expect(model.remoteMicrophone.status == nil)
    #expect(!model.needsRemoteMicrophoneBluetooth)
    fixture.send(0x3E, down: true)
    #expect(!model.remoteMicrophone.canStream())

    fixture.microphoneLoopbackAvailable = true
    model.refreshPermissions()
    #expect(model.remoteMicrophoneStatus == L10n.tr("遥控器麦克风需要蓝牙权限。"))
    #expect(model.needsRemoteMicrophoneBluetooth)
    #expect(model.remoteMicrophone.status == nil)

    fixture.microphoneBluetoothAuthorized = true
    model.remoteMicrophone.onBluetoothAuthorizationChanged()
    #expect(model.remoteMicrophoneStatus == L10n.tr("无法确认所选遥控器的蓝牙身份。"))
    #expect(!model.needsRemoteMicrophoneBluetooth)
    #expect(!model.remoteMicrophone.canStream())
    fixture.send(0x3E, down: false)
    fixture.send(0x3E, down: true)
    #expect(model.remoteMicrophone.canStream())
}

@Test @MainActor
func onlyAnAcceptedPhysicalVoicePressAuthorizesAudioUntilReleaseOrInterruption() {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let model = fixture.model(in: folder)
    let microphone = model.remoteMicrophone
    #expect(microphone.status == L10n.tr("无法确认所选遥控器的蓝牙身份。"))
    #expect(!microphone.isConnected)
    #expect(!microphone.canStream())

    fixture.send(0x3E, down: true)
    #expect(microphone.canStream())
    #expect(fixture.voice.isEmpty)
    model.foregroundChanged() // The focus observer can notify without changing the target.
    #expect(microphone.canStream())
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

@Test @MainActor
func codexNativeVoiceCanAuthorizeAudioWhenReturnCaptureFailsWithoutAuthorizingSend() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = RoutingFixture()
    fixture.focus = .init(bundleID: AppTarget.chatGPT.bundleID, pid: 14)
    let session = CodexConversationFixture()
    let model = fixture.model(in: folder, codexAccess: .init(session: { _ in session }, scroll: { _, _ in nil }))
    model.selectEditingApp(.chatGPT)
    let preset = try #require(model.profiles.first(where: model.isCodexPreset))
    try #require(model.selectProfile(preset.id))
    fixture.captured = false

    fixture.send(0x3E, down: true)
    #expect(model.remoteMicrophone.canStream())
    #expect(session.reads == 0)
    #expect(fixture.voice.isEmpty)
    fixture.tap(0x28)
    #expect(session.sent.isEmpty)
    fixture.send(0x3E, down: false)
    #expect(!model.remoteMicrophone.canStream())
}

@Test
func rc003NegotiatesOnlyAfterControlThenAudioNotificationsAreConfirmed() {
    var setup = ATVVNotificationSetup()
    let callbacks: [ATVVNotificationSetup.Channel] = [.audio, .control, .control, .audio, .audio, .control]
    let accepted = callbacks.map { setup.confirm($0) }
    #expect(accepted == [false, true, false, true, false, false])
}
