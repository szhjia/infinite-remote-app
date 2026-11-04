import Foundation

public struct DeviceID: Codable, Hashable, Sendable {
    public let vendor: Int
    public let product: Int
    public let name: String
    public let serial: String?

    public init(vendor: Int, product: Int, name: String, serial: String? = nil) {
        self.vendor = vendor
        self.product = product
        self.name = name
        self.serial = serial
    }

    public var modelCode: String { String(format: "%04X:%04X", vendor, product) }
}

public struct InputCode: Codable, Hashable, Sendable {
    public let collectionPage: Int
    public let collectionUsage: Int
    public let page: Int
    public let usage: Int
    public let report: Int
    public let value: Int

    public init(collectionPage: Int, collectionUsage: Int, page: Int, usage: Int, report: Int, value: Int) {
        self.collectionPage = collectionPage
        self.collectionUsage = collectionUsage
        self.page = page
        self.usage = usage
        self.report = report
        self.value = value
    }

    public var label: String {
        String(format: "%02X:%02X / %02X:%02X · R%d · %d", collectionPage, collectionUsage, page, usage, report, value)
    }
}

public enum RemoteLayout: String, Codable, CaseIterable, Sendable {
    case xiaomi2Pro, generic
}

public struct LearnedKey: Codable, Equatable, Sendable {
    public var slot: String
    public var input: InputCode
}

public struct RemoteMap: Codable, Equatable, Sendable {
    public let device: DeviceID
    public var layout: RemoteLayout = .xiaomi2Pro
    public var keys: [LearnedKey] = []

    public mutating func learn(_ code: InputCode, as slot: String) {
        keys.removeAll { $0.slot == slot || $0.input == code }
        keys.append(LearnedKey(slot: slot, input: code))
    }

    public mutating func forget(_ slot: String) { keys.removeAll { $0.slot == slot } }
    public func input(for slot: String) -> InputCode? { keys.first { $0.slot == slot }?.input }
    public func slot(for input: InputCode) -> String? { keys.first { $0.input == input }?.slot }
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    // A platform-specific key code. Other OSes must record their own shortcut.
    public var platform: String
    public var keyCode: UInt16
    public var modifiers: Set<Modifier>
    public var keyName: String

    public enum Modifier: String, Codable, Sendable { case command, option, control, shift }

    public init(platform: String = "macOS", keyCode: UInt16, modifiers: Set<Modifier>, keyName: String) {
        self.platform = platform
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    public var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
        + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + keyName
    }
}

public enum AgentAction: Codable, Equatable, Sendable {
    case openApp
    case openLink(String)
    case shortcut(KeyboardShortcut)
    case chatBar
    case nextAgent
}

public struct AppTarget: Codable, Equatable, Sendable {
    public var bundleID: String
    public var path: String?

    public init(bundleID: String, path: String? = nil) {
        self.bundleID = bundleID
        self.path = path
    }
}

public struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var target: AppTarget?
    public var actions: [String: AgentAction]

    public init(id: String = UUID().uuidString, name: String, target: AppTarget?, actions: [String: AgentAction] = [:]) {
        self.id = id
        self.name = name
        self.target = target
        self.actions = actions
    }

    fileprivate static let originalCodex = AgentProfile(
        id: "codex", name: "Codex", target: .init(bundleID: "com.openai.codex"),
        actions: ["ok": .openApp, "menu": .nextAgent, "key1": .openApp]
    )

    fileprivate static let codexChat = AgentProfile(
        id: originalCodex.id, name: originalCodex.name, target: originalCodex.target,
        actions: originalCodex.actions.merging([
            "home": .shortcut(.init(keyCode: 45, modifiers: [.command], keyName: "N")),
            "ok": .shortcut(.init(keyCode: 36, modifiers: [.command], keyName: "Return")),
            "back": .shortcut(.init(keyCode: 53, modifiers: [], keyName: "Esc"))
        ]) { _, shortcut in shortcut }
    )

    public static let presets: [AgentProfile] = [
        .init(id: "chatgpt", name: "ChatGPT", target: .init(bundleID: "com.openai.chat"), actions: [
            "ok": .openLink("https://chatgpt.com/"), "menu": .nextAgent, "key1": .openLink("https://chatgpt.com/")
        ]),
        codexChat,
        .init(id: "cursor", name: "Cursor", target: .init(bundleID: "com.todesktop.230313mzl4w4u92"), actions: [
            "ok": .openApp, "menu": .nextAgent, "key1": .openApp
        ]),
        .init(id: "claude-code", name: "Claude Code · 终端", target: .init(bundleID: "com.apple.Terminal"), actions: [
            "ok": .openApp, "menu": .nextAgent, "key1": .openApp
        ])
    ]
}

public struct Configuration: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version = Self.currentVersion
    public var activeAgentID = "chatgpt"
    public var selectedDevice: DeviceID?
    public var remotes: [RemoteMap] = []
    public var agents = AgentProfile.presets

    public init() {}

    public mutating func upgradeFromVersionOne() {
        guard version == 1 else { return }
        if let index = agents.firstIndex(of: AgentProfile.originalCodex) {
            agents[index] = AgentProfile.codexChat
        }
        version = Self.currentVersion
    }

    public var activeAgent: AgentProfile? { agents.first { $0.id == activeAgentID } }
    public var activeRemote: RemoteMap? { remotes.first { $0.device == selectedDevice } }

    public mutating func selectDevice(_ device: DeviceID) {
        selectedDevice = device
        if !remotes.contains(where: { $0.device == device }) {
            let layout: RemoteLayout = device.vendor == 0x2717 && device.product == 0x32B8 ? .xiaomi2Pro : .generic
            remotes.append(RemoteMap(device: device, layout: layout))
        }
    }

    public mutating func updateRemote(_ edit: (inout RemoteMap) -> Void) {
        guard let index = remotes.firstIndex(where: { $0.device == selectedDevice }) else { return }
        edit(&remotes[index])
    }

    public mutating func nextAgent() {
        guard !agents.isEmpty else { return }
        let index = agents.firstIndex { $0.id == activeAgentID }.map { ($0 + 1) % agents.count } ?? 0
        activeAgentID = agents[index].id
    }

    public func match(device: DeviceID, input: InputCode) -> String? {
        guard device == selectedDevice else { return nil }
        return activeRemote?.slot(for: input)
    }
}

public struct InputEdges<Endpoint: Hashable> {
    private struct Element: Hashable {
        let endpoint: Endpoint
        let cookie: Int
    }
    private var held: [Element: Int] = [:]

    public init() {}

    // An analog/button-array element may change from one active value to another
    // without emitting an idle value in between (e.g. a four-way HID hat).
    public mutating func press(endpoint: Endpoint, cookie: Int, value: Int, isActive: Bool) -> Bool {
        let key = Element(endpoint: endpoint, cookie: cookie)
        if !isActive {
            held.removeValue(forKey: key)
            return false
        }
        return held.updateValue(value, forKey: key) != value
    }

    public mutating func remove(endpoint: Endpoint) {
        held = held.filter { $0.key.endpoint != endpoint }
    }
}
