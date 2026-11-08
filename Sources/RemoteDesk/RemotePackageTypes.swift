import Foundation
import RemoteCore

struct LocalizedText: Codable, Sendable, Equatable {
    let translations: [String: String]
    let isLegacy: Bool

    init(_ value: String) { translations = ["en": value]; isLegacy = true }
    init(translations: [String: String]) { self.translations = translations; isLegacy = false }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacy = try? container.decode(String.self) { self.init(legacy) }
        else { self.init(translations: try container.decode([String: String].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(translations)
    }

    func resolve(locale: Locale = L10n.locale) -> String {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = identifier.split(separator: "-").first.map(String.init) ?? "en"
        return translations[identifier] ?? translations[language] ?? translations["en"] ?? ""
    }

    var isValid: Bool {
        guard let english = translations["en"], !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return translations.allSatisfy {
            !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count <= 4096
        }
    }
}

struct RemoteBrand: Codable, Sendable, Equatable {
    let id: String
    let name: LocalizedText
    let logo: String?
}

struct RemoteBehavior: Codable, Sendable, Equatable {
    var coalescedKeys: [String] = []
    var deferredKeys: [String] = []
    var nativeDictationKeys: [String] = []
    var consumesContextMenu: Bool = false

    static let empty = RemoteBehavior()

    init(coalescedKeys: [String] = [], deferredKeys: [String] = [], nativeDictationKeys: [String] = [],
         consumesContextMenu: Bool = false) {
        self.coalescedKeys = coalescedKeys
        self.deferredKeys = deferredKeys
        self.nativeDictationKeys = nativeDictationKeys
        self.consumesContextMenu = consumesContextMenu
    }

    private enum CodingKeys: String, CodingKey {
        case coalescedKeys, deferredKeys, nativeDictationKeys, consumesContextMenu
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coalescedKeys = try container.decodeIfPresent([String].self, forKey: .coalescedKeys) ?? []
        deferredKeys = try container.decodeIfPresent([String].self, forKey: .deferredKeys) ?? []
        nativeDictationKeys = try container.decodeIfPresent([String].self, forKey: .nativeDictationKeys) ?? []
        consumesContextMenu = try container.decodeIfPresent(Bool.self, forKey: .consumesContextMenu) ?? false
    }

    func isValid(keys: Set<String>) -> Bool {
        [coalescedKeys, deferredKeys, nativeDictationKeys].allSatisfy {
            Set($0).count == $0.count && $0.allSatisfy(keys.contains)
        }
    }
}

struct PackageVersion: Comparable, Equatable, Sendable {
    let major: UInt32
    let minor: UInt32
    let patch: UInt32

    init(_ text: String) throws {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let major = UInt32(components[0]), let minor = UInt32(components[1]), let patch = UInt32(components[2]) else {
            throw RemotePackageError.invalid(L10n.tr("版本号必须为数字 major.minor.patch 格式。"))
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

func validPackageID(_ id: String) -> Bool {
    let bytes = Array(id.utf8)
    return (1...63).contains(bytes.count) && bytes.first.map { (48...57).contains($0) || (97...122).contains($0) } == true
        && bytes.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
}

func validPackageFilename(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 255
        && !name.contains("/") && !name.contains("\\") && !name.contains(":")
        && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

extension AgentAction {
    var validPackageDefault: Bool { validPackageDefault(protocolVersion: 2) }

    func validPackageDefault(protocolVersion: Int) -> Bool {
        switch self {
        case let .openLink(text):
            guard protocolVersion == 1, text.count <= 4096,
                  let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
            return ["https", "http"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
        case let .shortcut(shortcut), let .foregroundKey(shortcut):
            return shortcut.platform == "macOS" && !shortcut.keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && shortcut.keyName.count <= 64
        case .systemShortcut:
            return true
        case .chatBar, .nextAgent:
            return protocolVersion == 1
        case .openFinder, .finder, .codexConversation, .chatGPTDraft, .systemDictation, .voiceShortcut:
            return false // These actions belong to the host's per-app configuration.
        case .openApp, .dictation, .displaySleep, .toggleDisplays, .appleMenu,
             .lockScreen, .showDesktop, .volumeUp, .volumeDown, .mediaChooser, .appSwitcher:
            return true
        }
    }
}
