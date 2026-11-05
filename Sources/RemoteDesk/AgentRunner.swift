import AppKit
import ApplicationServices
import CoreGraphics
import RemoteCore

@MainActor
enum AgentRunner {
    enum Failure: LocalizedError {
        case missingApp, permission, unsupportedKey, unsupportedAction
        var errorDescription: String? {
            switch self {
            case .missingApp: "找不到目标应用。请安装 ChatGPT 桌面端。"
            case .permission: "发送快捷键需要「辅助功能」权限。"
            case .unsupportedKey: "这个快捷键不是在 macOS 上录入的，请重新录入。"
            case .unsupportedAction: "此动作无法在当前配置中执行。"
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

    static func run(_ action: AgentAction, target: AppTarget?) async throws {
        switch action {
        case .openApp:
            let app = try await openApp(target)
            raiseWindow(of: app)
        case let .shortcut(shortcut):
            guard shortcut.platform == "macOS" else { throw Failure.unsupportedKey }
            guard CGPreflightPostEventAccess() else { throw Failure.permission }
            let app = try await openApp(target)
            try post(shortcut, pid: app.processIdentifier)
        case .toggleDisplays:
            try await DisplayToggle.shared.toggle()
        case .displaySleep:
            try await SystemActions.sleepDisplay()
        case .appleMenu:
            try SystemActions.openAppleMenu()
        case let .systemShortcut(shortcut):
            try SystemActions.send(shortcut)
        case let .foregroundKey(shortcut):
            guard shortcut.platform == "macOS" else { throw Failure.unsupportedKey }
            guard CGPreflightPostEventAccess() else { throw Failure.permission }
            try post(shortcut, pid: nil)
        case .lockScreen:
            try SystemActions.lockScreen()
        case .showDesktop:
            try SystemActions.showDesktop()
        case .volumeUp, .volumeDown:
            try SystemActions.changeVolume(up: action == .volumeUp)
        case .mediaChooser, .appSwitcher, .dictation, .openLink, .chatBar, .nextAgent:
            throw Failure.unsupportedAction
        }
    }

    private static func openApp(_ target: AppTarget?) async throws -> NSRunningApplication {
        guard let url = appURL(target) else { throw Failure.missingApp }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        return try await NSWorkspace.shared.openApplication(at: url, configuration: options)
    }

    private static func raiseWindow(of app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = Accessibility.element(application, kAXFocusedWindowAttribute)
                ?? Accessibility.element(application, kAXMainWindowAttribute)
                ?? (Accessibility.value(application, kAXWindowsAttribute) as? [AXUIElement])?.first else { return }
        if Accessibility.value(window, kAXMinimizedAttribute) as? Bool == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func post(_ shortcut: KeyboardShortcut, pid: pid_t?) throws {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        try post(keyCode: shortcut.keyCode, flags: flags, pid: pid)
    }

    static func post(keyCode: UInt16, flags: CGEventFlags, pid: pid_t?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw Failure.unsupportedKey
        }
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
