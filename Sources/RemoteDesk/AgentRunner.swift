import AppKit
import CoreGraphics
import RemoteCore

@MainActor
enum AgentRunner {
    enum Failure: LocalizedError {
        case missingApp, invalidLink, permission, unsupportedKey, chatBarNotRunning
        var errorDescription: String? {
            switch self {
            case .missingApp: "找不到目标应用。请在当前方案里选择已安装的应用。"
            case .invalidLink: "链接无法打开。请填写完整的 HTTPS 或 HTTP 地址。"
            case .permission: "发送快捷键需要「辅助功能」权限。"
            case .unsupportedKey: "这个快捷键不是在 macOS 上录入的，请重新录入。"
            case .chatBarNotRunning: "请先启动支持 ⌥Space Chat Bar 的 ChatGPT 桌面应用。也可以改用打开网页。"
            }
        }
    }

    static func appURL(_ target: AppTarget?) -> URL? {
        guard let target else { return nil }
        if let path = target.path {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == target.bundleID { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID)
    }

    static func webURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    static func run(_ action: AgentAction, target: AppTarget?) async throws {
        switch action {
        case .openApp:
            _ = try await openApp(target)
        case let .openLink(address):
            guard let url = webURL(address), NSWorkspace.shared.open(url) else { throw Failure.invalidLink }
        case let .shortcut(shortcut):
            guard shortcut.platform == "macOS" else { throw Failure.unsupportedKey }
            guard CGPreflightPostEventAccess() else { throw Failure.permission }
            let app = try await openApp(target)
            try post(shortcut, pid: app.processIdentifier)
        case .chatBar:
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").isEmpty else {
                throw Failure.chatBarNotRunning
            }
            guard CGPreflightPostEventAccess() else { throw Failure.permission }
            try post(.init(keyCode: 49, modifiers: [.option], keyName: "Space"), pid: nil)
        case .nextAgent:
            break // Handled by the profile coordinator.
        }
    }

    private static func openApp(_ target: AppTarget?) async throws -> NSRunningApplication {
        guard let url = appURL(target) else { throw Failure.missingApp }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        return try await NSWorkspace.shared.openApplication(at: url, configuration: options)
    }

    private static func post(_ shortcut: KeyboardShortcut, pid: pid_t?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else {
            throw Failure.unsupportedKey
        }
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
