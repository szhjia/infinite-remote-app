import Foundation
import RemoteCore
import Testing

private let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
private let other = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器", serial: "another")
private let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x28, report: 1, value: 1)
private let consumerEnter = InputCode(collectionPage: 12, collectionUsage: 1, page: 7, usage: 0x28, report: 1, value: 1)

@Test func chatGPTAndSystemBindingsRoundTripWithLearnedDevice() throws {
    var config = Configuration()
    config.selectDevice(xiaomi)
    config.updateRemote { $0.learn(enter, as: "ok") }
    let shortcut = SystemHotKey(keyCode: 120, flags: 262144)
    config.agents[0].actions["tv"] = .systemShortcut(shortcut)

    let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
    #expect(restored.activeAgent?.name == "ChatGPT")
    #expect(restored.match(device: xiaomi, input: enter) == "ok")
    #expect(restored.activeAgent?.actions["ok"] == .shortcut(AgentProfile.sendDraft))
    #expect(restored.activeAgent?.actions["tv"] == .systemShortcut(shortcut))
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
    config.updateRemote { $0.learn(enter, as: "ok") }
    #expect(config.match(device: other, input: enter) == "ok")
    config.selectDevice(xiaomi)
    #expect(config.match(device: xiaomi, input: enter) == "back")
}

@Test func heldKeysDoNotRetriggerAndReleasesKeepThePressedValue() {
    var edges = InputEdges<Int>()
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 23, isActive: true) == [.pressed(23)])
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 23, isActive: true).isEmpty)
    #expect(edges.changes(endpoint: 2, cookie: 9, value: 23, isActive: true) == [.pressed(23)])
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 0, isActive: false) == [.released(23)])
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 0, isActive: false).isEmpty)
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 23, isActive: true) == [.pressed(23)])
    edges.remove(endpoint: 1)
    #expect(edges.changes(endpoint: 1, cookie: 9, value: 0, isActive: false).isEmpty)
    #expect(edges.changes(endpoint: 2, cookie: 9, value: 23, isActive: true).isEmpty)
}

@Test func hatZeroCanBePressedAndDirectionChangesReplaceOldValueFirst() {
    var edges = InputEdges<Int>()
    #expect(edges.changes(endpoint: 1, cookie: 1, value: 0, isActive: true) == [.pressed(0)])
    #expect(edges.changes(endpoint: 1, cookie: 1, value: 2, isActive: true) == [.replaced(0), .pressed(2)])
    #expect(edges.changes(endpoint: 1, cookie: 1, value: 8, isActive: false) == [.released(2)])
    #expect(edges.changes(endpoint: 1, cookie: 1, value: 2, isActive: true) == [.pressed(2)])
}
