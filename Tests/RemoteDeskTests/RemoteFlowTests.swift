import Foundation
import RemoteCore
@testable import RemoteDesk
import Testing

@MainActor
private final class InputFixture: RemoteInputSource {
    let devices: [DeviceID]
    var state: InputMonitorState = .permission
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onPress: (DeviceID, InputCode) -> Void = { _, _ in }
    var selectedDevice: DeviceID?

    init(devices: [DeviceID]) {
        self.devices = devices
    }

    func refresh() -> InputMonitorState {
        onDevices(devices)
        return state
    }
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
    let codexIndex = try #require(old.agents.firstIndex { $0.id == "codex" })
    old.agents[codexIndex].actions = [
        "ok": customized ? .nextAgent : .openApp, "menu": .nextAgent, "key1": .openApp
    ]
    try JSONEncoder().encode(old).write(to: storeURL)

    let model = RemoteModel(hid: InputFixture(devices: [device]), storeURL: storeURL, runAction: { _, _ in })
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storeURL))
    #expect(saved == model.config)
    #expect(saved.version == Configuration.currentVersion)
    #expect(saved.activeAgentID == old.activeAgentID)
    #expect(saved.remotes == old.remotes)
    #expect(saved.agents.filter { $0.id != "codex" } == old.agents.filter { $0.id != "codex" })

    let codex = saved.agents[codexIndex]
    if customized {
        #expect(codex == old.agents[codexIndex])
    } else {
        #expect(codex.actions["home"] == .shortcut(.init(keyCode: 45, modifiers: [.command], keyName: "N")))
        #expect(codex.actions["ok"] == .shortcut(.init(keyCode: 36, modifiers: [.command], keyName: "Return")))
        #expect(codex.actions["back"] == .shortcut(.init(keyCode: 53, modifiers: [], keyName: "Esc")))
    }
}

@Test @MainActor
func selectedRemoteLearnsOnceAndRunsTheCurrentAgentActionAfterRestart() async throws {
    let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
    let other = DeviceID(vendor: 1, product: 2, name: "另一个遥控器")
    // IOKit reports this remote's keyboard array usage in the value field.
    let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: Int(UInt32.max), report: 1, value: 0x28)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")

    var dispatched: [(AgentAction, AppTarget?)] = []
    let runAction: @MainActor (AgentAction, AppTarget?) async throws -> Void = { action, target in
        dispatched.append((action, target))
    }
    let input = InputFixture(devices: [xiaomi, other])
    let model = RemoteModel(hid: input, storeURL: storeURL, runAction: runAction)

    model.refreshPermissions()
    model.selectDevice(xiaomi)
    #expect(model.connected)
    #expect(input.selectedDevice == xiaomi)
    #expect(model.layout == .xiaomi2Pro)
    model.startLearning()
    #expect(model.learning == nil)

    input.state = .listening
    model.refreshPermissions()
    model.startLearning()
    input.onPress(other, enter)
    #expect(model.learning == "ok")
    input.onPress(xiaomi, enter)
    #expect(model.learning == nil)
    #expect(model.learnedCount == 1)
    #expect(!model.isRunning)

    let customShortcut = RemoteCore.KeyboardShortcut(keyCode: 45, modifiers: [.command], keyName: "N")
    model.selectAgent("codex")
    model.setAction(.shortcut(customShortcut), for: "ok", in: "codex")

    let reopenedInput = InputFixture(devices: [xiaomi, other])
    let reopened = RemoteModel(hid: reopenedInput, storeURL: storeURL, runAction: runAction)
    #expect(reopenedInput.selectedDevice == xiaomi)
    #expect(reopened.learnedCount == 1)

    reopened.refreshPermissions()
    reopenedInput.onPress(xiaomi, enter)
    #expect(!reopened.isRunning)

    reopenedInput.state = .listening
    reopened.refreshPermissions()
    reopened.isEnabled = false
    reopenedInput.onPress(xiaomi, enter)
    #expect(!reopened.isRunning)

    reopened.isEnabled = true
    reopenedInput.onPress(xiaomi, enter)
    try await waitForAction(on: reopened)
    try #require(dispatched.count == 1)
    #expect(dispatched[0].0 == .shortcut(customShortcut))
    #expect(dispatched[0].1?.bundleID == "com.openai.codex")

    reopened.selectAgent("chatgpt")
    reopenedInput.onPress(xiaomi, enter)
    try await waitForAction(on: reopened)
    try #require(dispatched.count == 2)
    #expect(dispatched[1].0 == .openLink("https://chatgpt.com/"))
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
