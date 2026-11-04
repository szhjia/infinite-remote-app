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

    public var isSupportedRemote: Bool { vendor == 0x2717 && product == 0x32B8 }

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

public struct SystemHotKey: Codable, Hashable, Sendable {
    public let keyCode: UInt16
    public let flags: UInt64

    public init(keyCode: UInt16, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags
    }
}

public enum AgentAction: Codable, Equatable, Sendable {
    case openApp
    case openLink(String)
    case shortcut(KeyboardShortcut)
    case chatBar
    case nextAgent
    case dictation
    case displaySleep
    case appleMenu
    case systemShortcut(SystemHotKey)
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

    public static let newChat = KeyboardShortcut(keyCode: 45, modifiers: [.command], keyName: "N")
    public static let sendDraft = KeyboardShortcut(keyCode: 36, modifiers: [.command], keyName: "Return")
    public static let stop = KeyboardShortcut(keyCode: 53, modifiers: [], keyName: "Esc")

    public static let chatGPT = AgentProfile(
        id: "codex", name: "ChatGPT", target: .init(bundleID: "com.openai.codex"),
        actions: [
            "power": .displaySleep, "voice": .dictation, "menu": .appleMenu,
            "home": .shortcut(newChat), "ok": .shortcut(sendDraft), "back": .shortcut(stop)
        ]
    )

    public static let presets = [chatGPT]

}

public struct Configuration: Codable, Equatable, Sendable {
    public static let currentVersion = 3
    public var version = Self.currentVersion
    public var activeAgentID = AgentProfile.chatGPT.id
    public var selectedDevice: DeviceID?
    public var remotes: [RemoteMap] = []
    public var agents = AgentProfile.presets

    public init() {}

    public mutating func upgradeLegacy() {
        guard version == 1 || version == 2 else { return }
        var profile = AgentProfile.chatGPT
        let codexProfiles = agents.filter { $0.target?.bundleID == profile.target?.bundleID }
        let legacy = codexProfiles.first { $0.id == activeAgentID } ?? codexProfiles.first { $0.id == profile.id }
        if let legacy, !(version == 1 && legacy == AgentProfile.originalCodex) {
            profile.target = legacy.target
            profile.actions = ["power": .displaySleep, "voice": .dictation]
            for (slot, action) in legacy.actions {
                switch action {
                case .nextAgent where slot == "menu":
                    profile.actions[slot] = .appleMenu
                case .openApp, .dictation, .displaySleep, .appleMenu, .systemShortcut:
                    profile.actions[slot] = action
                case let .shortcut(shortcut) where shortcut.platform == "macOS":
                    profile.actions[slot] = action
                default:
                    break
                }
            }
        }
        profile.actions = profile.actions.filter { !$0.key.hasPrefix("key") }
        agents = [profile]
        activeAgentID = profile.id
        remotes = remotes.filter { $0.device.isSupportedRemote }.map { remote in
            var remote = remote
            remote.layout = .xiaomi2Pro
            return remote
        }
        if selectedDevice?.isSupportedRemote != true { selectedDevice = nil }
        version = Self.currentVersion
    }

    public var activeAgent: AgentProfile? { agents.first { $0.id == activeAgentID } }
    public var activeRemote: RemoteMap? { remotes.first { $0.device == selectedDevice } }

    public mutating func selectDevice(_ device: DeviceID) {
        guard device.isSupportedRemote else { return }
        selectedDevice = device
        if !remotes.contains(where: { $0.device == device }) {
            remotes.append(RemoteMap(device: device))
        }
    }

    public mutating func updateRemote(_ edit: (inout RemoteMap) -> Void) {
        guard let index = remotes.firstIndex(where: { $0.device == selectedDevice }) else { return }
        edit(&remotes[index])
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

    public enum Change: Equatable {
        case pressed(Int)
        case released(Int)
        case replaced(Int)
    }

    // An array or hat may replace its active value without passing through neutral.
    public mutating func changes(endpoint: Endpoint, cookie: Int, value: Int, isActive: Bool) -> [Change] {
        let key = Element(endpoint: endpoint, cookie: cookie)
        if !isActive {
            return held.removeValue(forKey: key).map { [.released($0)] } ?? []
        }
        let previous = held.updateValue(value, forKey: key)
        if previous == value { return [] }
        return previous.map { [.replaced($0), .pressed(value)] } ?? [.pressed(value)]
    }

    public mutating func remove(endpoint: Endpoint) {
        held = held.filter { $0.key.endpoint != endpoint }
    }
}
