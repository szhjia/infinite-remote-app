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

    // Compatibility predicate used only to migrate pre-package configurations.
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
    public var layout: RemoteLayout = .generic
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

    public var isVoiceCombination: Bool {
        platform == "macOS" && !modifiers.isEmpty && keyCode < 128 && !keyName.isEmpty && keyName.count <= 64
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
    case openFinder
    case openLink(String)
    case shortcut(KeyboardShortcut)
    case chatBar
    case nextAgent
    case dictation
    case displaySleep
    case toggleDisplays
    case appleMenu
    case systemShortcut(SystemHotKey)
    case foregroundKey(KeyboardShortcut)
    case lockScreen
    case showDesktop
    case volumeUp
    case volumeDown
    case mediaChooser
    case appSwitcher
    case finder(FinderCommand)
    case codexConversation(CodexConversationCommand)
    case chatGPTDraft
    case systemDictation
    case voiceShortcut(VoiceProvider, KeyboardShortcut)

    public var isVoiceTrigger: Bool {
        switch self {
        case .dictation, .chatGPTDraft, .systemDictation, .voiceShortcut(.macOS, _): true
        default: false
        }
    }

    public var isRemovedVoiceBinding: Bool {
        if case .voiceShortcut(.weType, _) = self { return true }
        return false
    }
}

public enum CodexConversationCommand: String, Codable, Sendable {
    case scrollUp, scrollDown, sendTranscript, discardConfirmation
}

public enum FinderCommand: String, Codable, CaseIterable, Sendable {
    case up, down, left, right, pageUp, pageDown, sidebar, content, open, contextMenu, escape, parent, historyBack

    public var repeatsWhileHeld: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }
}

public enum VoiceProvider: String, Codable, Sendable {
    case macOS
    case weType // Legacy configurations and exported profiles still decode this value.
}

public struct AppTarget: Codable, Equatable, Sendable {
    public var bundleID: String
    public var path: String?

    public init(bundleID: String, path: String? = nil) {
        self.bundleID = bundleID
        self.path = path
    }

    public static let finder = Self(bundleID: "com.apple.finder")
    public static let chatGPT = Self(bundleID: "com.openai.codex")
}

public struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var target: AppTarget?
    public var modelID: String?
    public var actions: [String: AgentAction]

    public init(id: String = UUID().uuidString, name: String, target: AppTarget?, actions: [String: AgentAction] = [:],
                modelID: String? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.actions = actions
        self.modelID = modelID
    }

    fileprivate static let originalCodex = AgentProfile(
        id: "codex", name: "Codex", target: .init(bundleID: "com.openai.codex"),
        actions: ["ok": .openApp, "menu": .nextAgent, "key1": .openApp]
    )

    public static let newChat = KeyboardShortcut(keyCode: 45, modifiers: [.command], keyName: "N")
    public static let sendDraft = KeyboardShortcut(keyCode: 36, modifiers: [.command], keyName: "Return")
    public static let stop = KeyboardShortcut(keyCode: 53, modifiers: [], keyName: "Esc")
    public static let defaults = AgentProfile(
        id: "default", name: "默认配置", target: .init(bundleID: "com.openai.codex"),
        actions: [
            "power": .toggleDisplays, "power-long": .lockScreen, "voice": .dictation,
            "up": .foregroundKey(.init(keyCode: 126, modifiers: [], keyName: "↑")),
            "left": .foregroundKey(.init(keyCode: 123, modifiers: [], keyName: "←")),
            "right": .foregroundKey(.init(keyCode: 124, modifiers: [], keyName: "→")),
            "down": .foregroundKey(.init(keyCode: 125, modifiers: [], keyName: "↓")),
            "ok": .foregroundKey(.init(keyCode: 36, modifiers: [], keyName: "Return")),
            "back": .foregroundKey(stop), "home": .openApp, "plus": .volumeUp, "minus": .volumeDown,
            "menu": .appSwitcher, "tv": .mediaChooser
        ]
    )

    public static let chatGPT = AgentProfile(
        id: "codex", name: "ChatGPT", target: .init(bundleID: "com.openai.codex"),
        actions: [
            "power": .toggleDisplays, "power-long": .lockScreen, "voice": .dictation, "menu": .appleMenu,
            "home": .shortcut(newChat), "ok": .shortcut(sendDraft), "back": .shortcut(stop)
        ]
    )

}

public struct Configuration: Codable, Equatable, Sendable {
    public static let currentVersion = 12
    public var version = Self.currentVersion
    public var activeAgentID = AgentProfile.defaults.id
    public var activeAgentIDsByModel: [String: String]?
    public var activeProfilesByApp: [String: [String: String]]?
    public var addedAppsByModel: [String: [AppTarget]]?
    public var defaultVoiceByModel: [String: AgentAction]?
    public var disabledDefaultVoiceModelIDs: [String]?
    public var remoteMicrophoneEnabledByModel: [String: Bool]?
    public var selectedDevice: DeviceID?
    public var selectedModelID: String?
    public var verifiedRemoteDevices: [DeviceID]?
    public var remotes: [RemoteMap] = []
    public var agents: [AgentProfile] = []

    public init() {}

    public mutating func upgradeLegacy(installedModelIDs: Set<String> = []) {
        if (9...11).contains(version) {
            if version < 11 {
                defaultVoiceByModel = defaultVoiceByModel?.filter { !$0.value.isRemovedVoiceBinding }
                for index in agents.indices {
                    agents[index].actions = agents[index].actions.filter { !$0.value.isRemovedVoiceBinding }
                }
            }
            if let defaults = defaultVoiceByModel {
                // The legacy editor saved a dictionary even after clearing its last binding.
                // Missing entries in an existing dictionary previously meant no default action.
                let disabled = installedModelIDs.subtracting(defaults.keys)
                if !disabled.isEmpty { disabledDefaultVoiceModelIDs = disabled.sorted() }
            }
            version = Self.currentVersion
            return
        }
        if (6...8).contains(version) {
            migrateModelAssociations()
            version = Self.currentVersion
            return
        }
        if (3...5).contains(version) {
            var previousPreset = AgentProfile.chatGPT
            previousPreset.actions["power"] = .displaySleep
            if version < 5 { previousPreset.actions.removeValue(forKey: "power-long") }
            if let index = agents.firstIndex(of: previousPreset) {
                agents[index] = .chatGPT
            }
            migrateModelAssociations()
            version = Self.currentVersion
            return
        }
        guard version == 1 || version == 2 else { return }
        var profile = AgentProfile.chatGPT
        let codexProfiles = agents.filter { $0.target?.bundleID == profile.target?.bundleID }
        let legacy = codexProfiles.first { $0.id == activeAgentID } ?? codexProfiles.first { $0.id == profile.id }
        if let legacy, !(version == 1 && legacy == AgentProfile.originalCodex) {
            profile.target = legacy.target
            profile.actions = ["power": .toggleDisplays, "power-long": .lockScreen, "voice": .dictation]
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
        migrateModelAssociations()
        version = Self.currentVersion
    }

    public func activeProfileID(modelID: String, bundleID: String) -> String? {
        if let saved = activeProfilesByApp?[modelID]?[bundleID] { return saved }
        guard let legacyID = activeAgentIDsByModel?[modelID],
              agents.contains(where: { $0.modelID == modelID && $0.id == legacyID && $0.target?.bundleID == bundleID })
        else { return nil }
        return legacyID
    }

    public mutating func selectProfile(_ id: String, modelID: String, bundleID: String) {
        var selections = activeProfilesByApp ?? [:]
        selections[modelID, default: [:]][bundleID] = id
        activeProfilesByApp = selections
    }

    private mutating func migrateModelAssociations() {
        // The pre-package configuration implicitly belonged to this legacy model.
        let legacyID = "xiaomi-2-pro"
        for index in agents.indices where agents[index].modelID == nil { agents[index].modelID = legacyID }
        if activeAgentIDsByModel?[legacyID] == nil {
            var ids = activeAgentIDsByModel ?? [:]
            ids[legacyID] = activeAgentID
            activeAgentIDsByModel = ids
        }
        if selectedModelID == nil, selectedDevice?.isSupportedRemote == true { selectedModelID = legacyID }
    }

    public var activeAgent: AgentProfile? {
        if activeAgentID == AgentProfile.defaults.id { return .defaults }
        return agents.first { $0.id == activeAgentID } ?? .defaults
    }
    public var activeRemote: RemoteMap? { remotes.first { $0.device == selectedDevice } }

    public mutating func selectDevice(_ device: DeviceID, layout: RemoteLayout = .generic) {
        selectedDevice = device
        if !remotes.contains(where: { $0.device == device }) {
            remotes.append(RemoteMap(device: device, layout: layout))
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
