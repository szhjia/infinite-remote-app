import Foundation
import RemoteCore
import Testing

private let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
private let other = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器", serial: "another")
private let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x28, report: 1, value: 1)
private let consumerEnter = InputCode(collectionPage: 12, collectionUsage: 1, page: 7, usage: 0x28, report: 1, value: 1)

@Test func profileSwitchAndPersistencePreserveLearnedDevice() throws {
    var config = Configuration()
    config.selectDevice(xiaomi)
    config.updateRemote { $0.learn(enter, as: "ok") }
    config.nextAgent()

    let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
    #expect(restored.activeAgent?.name == "Codex")
    #expect(restored.match(device: xiaomi, input: enter) == "ok")
    #expect(restored.activeAgent?.actions["ok"] == .shortcut(.init(keyCode: 36, modifiers: [.command], keyName: "Return")))
    #expect(restored.match(device: other, input: enter) == nil)
    #expect(restored.match(device: xiaomi, input: consumerEnter) == nil)
    #expect(restored == config)
}

@Test func learningSameSignalMovesRatherThanDuplicatesBinding() {
    var config = Configuration()
    config.selectDevice(xiaomi)
    config.updateRemote { $0.learn(enter, as: "ok"); $0.learn(enter, as: "back") }
    #expect(config.activeRemote?.input(for: "ok") == nil)
    #expect(config.match(device: xiaomi, input: enter) == "back")

    config.selectDevice(other)
    config.updateRemote { $0.learn(enter, as: "ok"); $0.layout = .generic }
    #expect(config.match(device: other, input: enter) == "ok")
    config.selectDevice(xiaomi)
    #expect(config.activeRemote?.layout == .xiaomi2Pro)
    #expect(config.match(device: xiaomi, input: enter) == "back")
}

@Test func heldKeysDoNotRetriggerAndEndpointsAreIndependent() {
    var edges = InputEdges<Int>()
    let first = edges.press(endpoint: 1, cookie: 9, value: 1, isActive: true)
    #expect(first)
    let repeated = edges.press(endpoint: 1, cookie: 9, value: 1, isActive: true)
    #expect(!repeated)
    let secondEndpoint = edges.press(endpoint: 2, cookie: 9, value: 1, isActive: true)
    #expect(secondEndpoint)
    let released = edges.press(endpoint: 1, cookie: 9, value: 0, isActive: false)
    #expect(!released)
    let pressedAgain = edges.press(endpoint: 1, cookie: 9, value: 1, isActive: true)
    #expect(pressedAgain)
    edges.remove(endpoint: 1)
    let reconnected = edges.press(endpoint: 1, cookie: 9, value: 1, isActive: true)
    #expect(reconnected)
    let stillHeld = edges.press(endpoint: 2, cookie: 9, value: 1, isActive: true)
    #expect(!stillHeld)
}

@Test func hatZeroCanBePressedAndDirectionChangesDoNotRequireNeutral() {
    var edges = InputEdges<Int>()
    let north = edges.press(endpoint: 1, cookie: 1, value: 0, isActive: true)
    #expect(north)
    let east = edges.press(endpoint: 1, cookie: 1, value: 2, isActive: true)
    #expect(east)
    let neutral = edges.press(endpoint: 1, cookie: 1, value: 8, isActive: false)
    #expect(!neutral)
    let eastAgain = edges.press(endpoint: 1, cookie: 1, value: 2, isActive: true)
    #expect(eastAgain)
}
