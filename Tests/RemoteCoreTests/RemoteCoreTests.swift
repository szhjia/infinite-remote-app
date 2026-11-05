import Foundation
import RemoteCore
import Testing

private let xiaomi = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器")
private let other = DeviceID(vendor: 0x2717, product: 0x32B8, name: "小米蓝牙语音遥控器", serial: "another")
private let enter = InputCode(collectionPage: 1, collectionUsage: 6, page: 7, usage: 0x28, report: 1, value: 1)
private let consumerEnter = InputCode(collectionPage: 12, collectionUsage: 1, page: 7, usage: 0x28, report: 1, value: 1)

@Test func chatGPTAndSystemBindingsRoundTripWithLearnedDevice() throws {
    var config = Configuration()
    config.agents = [.chatGPT]
    config.activeAgentID = AgentProfile.chatGPT.id
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

@Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
func mediaGridKeepsFocusInOccupiedCells(_ count: Int) {
    let grid = MediaGrid(count: count)
    let sizes = [(1, 0), (1, 1), (2, 1), (3, 2), (2, 2), (3, 2), (3, 2), (3, 3), (3, 3), (3, 3)]
    #expect(grid.columns == sizes[count].0)
    #expect(grid.rows == sizes[count].1)
    if count > 0 {
        #expect(grid.move(from: 0, toward: .left) == 0)
        #expect(grid.move(from: count - 1, toward: .down) == count - 1)
    }
    if count == 5 {
        #expect(grid.move(from: 2, toward: .down) == 2)
        #expect(grid.move(from: 1, toward: .down) == 4)
        #expect(grid.move(from: 2, toward: .right) == 2)
    }
}

@Test func builtInProfileRoutesVolumeDirectionsAndHomeToMacActions() {
    let actions = Configuration().activeAgent?.actions
    #expect(actions?["plus"] == .volumeUp)
    #expect(actions?["minus"] == .volumeDown)
    #expect(actions?["home"] == .openApp)
    #expect(actions?["menu"] == .appSwitcher)
    for (key, code) in [("up", UInt16(126)), ("left", 123), ("right", 124), ("down", 125)] {
        guard case let .foregroundKey(shortcut)? = actions?[key] else {
            Issue.record("Missing foreground key for \(key)")
            continue
        }
        #expect(shortcut.keyCode == code)
        #expect(shortcut.modifiers.isEmpty)
    }
}

@Test(arguments: [0, 1, 4, 9])
func mediaSwitcherKeepsEveryAppOnOneRow(_ count: Int) {
    let row = MediaGrid(count: count, singleRow: true)
    #expect(row.columns == max(1, count))
    #expect(row.rows == (count == 0 ? 0 : 1))
    if count > 1 {
        #expect(row.move(from: 0, toward: .right) == 1)
        #expect(row.move(from: 0, toward: .down) == 0)
        #expect(row.move(from: count - 1, toward: .right) == count - 1)
    }
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

@Test func configurationStoresArbitraryPackageHardwareWithoutManufacturerDefaults() {
    let device = DeviceID(vendor: 1234, product: 5678, name: "Independent Remote")
    var config = Configuration()
    config.selectDevice(device)
    #expect(config.selectedDevice == device)
    #expect(config.activeRemote?.layout == .generic)
    config.updateRemote { $0.learn(enter, as: "custom-confirm") }
    #expect(config.match(device: device, input: enter) == "custom-confirm")
}
