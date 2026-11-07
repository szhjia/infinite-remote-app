import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import RemoteCore

@MainActor
enum AgentRunner {
    static let finder = FinderNavigation()
    static let isChatGPTEnabled = Bundle.main.object(forInfoDictionaryKey: "InfiniteRemoteChatGPTEnabled") as? Bool ?? true
    private static let remoteEventTag: Int64 = 0x52444B4559

    enum Failure: LocalizedError {
        case missingApp, permission, unsupportedKey, unsupportedAction, focusChanged
        var errorDescription: String? {
            switch self {
            case .missingApp: L10n.tr("找不到目标应用。")
            case .permission: L10n.tr("发送快捷键需要「辅助功能」权限。")
            case .unsupportedKey: L10n.tr("这个快捷键不是在 macOS 上录入的，请重新录入。")
            case .unsupportedAction: L10n.tr("此动作无法在当前配置中执行。")
            case .focusChanged: L10n.tr("前台应用已变化，已取消快捷键。")
            }
        }
    }

    static func appURL(_ target: AppTarget?) -> URL? {
        guard let target else { return nil }
        guard isChatGPTEnabled || target.bundleID != AppTarget.chatGPT.bundleID else { return nil }
        if let path = target.path {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == target.bundleID { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID)
    }

    static func run(_ action: AgentAction, target: AppTarget?) async throws {
        switch action {
        case .openFinder:
            let app = try await openApp(.finder)
            if !raiseWindow(of: app) {
                if AXIsProcessTrusted(), CGPreflightPostEventAccess(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    try post(keyCode: UInt16(kVK_ANSI_N), flags: .maskCommand, pid: app.processIdentifier)
                } else if !AXIsProcessTrusted() {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
                }
            }
        case .openApp:
            let app = try await openApp(target)
            _ = raiseWindow(of: app)
        case let .shortcut(shortcut):
            guard shortcut.platform == "macOS" else { throw Failure.unsupportedKey }
            guard CGPreflightPostEventAccess() else { throw Failure.permission }
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == target?.bundleID else {
                throw Failure.focusChanged
            }
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
            guard let app = NSWorkspace.shared.frontmostApplication, target == nil || app.bundleIdentifier == target?.bundleID else {
                throw Failure.focusChanged
            }
            try post(shortcut, pid: app.processIdentifier)
        case let .finder(command):
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw Failure.permission }
            guard let context = ForegroundContext.current(), context.bundleID == AppTarget.finder.bundleID else {
                throw Failure.focusChanged
            }
            try finder.run(command, in: context)
        case .lockScreen:
            try SystemActions.lockScreen()
        case .showDesktop:
            try SystemActions.showDesktop()
        case .volumeUp, .volumeDown:
            try SystemActions.changeVolume(up: action == .volumeUp)
        case .mediaChooser, .appSwitcher, .dictation, .openLink, .chatBar, .nextAgent, .chatGPTDraft, .voiceShortcut:
            throw Failure.unsupportedAction
        }
    }

    private static func openApp(_ target: AppTarget?) async throws -> NSRunningApplication {
        guard let url = appURL(target) else { throw Failure.missingApp }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        return try await NSWorkspace.shared.openApplication(at: url, configuration: options)
    }

    private static func raiseWindow(of app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let window = Accessibility.element(application, kAXFocusedWindowAttribute)
                ?? Accessibility.element(application, kAXMainWindowAttribute)
                ?? (Accessibility.value(application, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return false }
        if Accessibility.value(window, kAXMinimizedAttribute) as? Bool == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return true
    }

    private static func flags(for shortcut: KeyboardShortcut) -> CGEventFlags {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    static func post(_ shortcut: KeyboardShortcut, pid: pid_t?) throws {
        try post(keyCode: shortcut.keyCode, flags: flags(for: shortcut), pid: pid)
    }

    static func postVoiceEdge(_ shortcut: KeyboardShortcut, down: Bool) throws {
        guard shortcut.platform == "macOS", CGPreflightPostEventAccess() else { throw Failure.permission }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down) else {
            throw Failure.unsupportedAction
        }
        event.flags = flags(for: shortcut)
        postRemoteEvent(event, pid: nil)
    }

    static func post(keyCode: UInt16, flags: CGEventFlags, pid: pid_t?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw Failure.unsupportedKey
        }
        down.flags = flags
        up.flags = flags
        postRemoteEvent(down, pid: pid)
        postRemoteEvent(up, pid: pid)
    }

    static func isRemoteEvent(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == remoteEventTag
    }

    static func postRemoteEvent(_ event: CGEvent, pid: pid_t?) {
        event.setIntegerValueField(.eventSourceUserData, value: remoteEventTag)
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}
