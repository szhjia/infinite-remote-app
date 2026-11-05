import AppKit
import ApplicationServices
import Carbon
import IOKit
import RemoteCore

@MainActor
enum SystemActions {
    enum Failure: LocalizedError {
        case hotKeysUnavailable, shortcutChanged, appleMenuUnavailable, displaySleepFailed, permission

        var errorDescription: String? {
            switch self {
            case .hotKeysUnavailable: "暂时无法读取 macOS 快捷键。"
            case .shortcutChanged: "此快捷键已改绑或停用，请重新选择。"
            case .appleMenuUnavailable: "当前无法打开苹果菜单。"
            case .displaySleepFailed: "macOS 未能关闭显示器。"
            case .permission: "此动作需要「辅助功能」权限。"
            }
        }
    }

    static func enabledHotKeys() throws -> [SystemHotKey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]] else { throw Failure.hotKeysUnavailable }
        let keys = entries.compactMap { entry -> SystemHotKey? in
            guard entry["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  let code = entry["kHISymbolicHotKeyCode"] as? NSNumber,
                  let keyCode = UInt16(exactly: code.intValue), keyCode < 0xFF,
                  let flags = entry["kHISymbolicHotKeyModifiers"] as? NSNumber else { return nil }
            return SystemHotKey(keyCode: keyCode, flags: flags.uint64Value)
        }
        return Array(Set(keys)).sorted { ($0.keyCode, $0.flags) < ($1.keyCode, $1.flags) }
    }

    static func validate(_ shortcut: SystemHotKey, enabled: [SystemHotKey]) throws {
        guard enabled.contains(shortcut) else { throw Failure.shortcutChanged }
    }

    static func send(_ shortcut: SystemHotKey) throws {
        guard CGPreflightPostEventAccess() else { throw Failure.permission }
        try validate(shortcut, enabled: enabledHotKeys())
        try AgentRunner.post(keyCode: shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.flags), pid: nil)
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    static func sleepDisplay() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw Failure.displaySleepFailed }
    }

    static func lockScreen() throws {
        guard CGPreflightPostEventAccess() else { throw Failure.permission }
        try AgentRunner.post(keyCode: UInt16(kVK_ANSI_Q), flags: [.maskControl, .maskCommand], pid: nil)
    }

    static func showDesktop() throws {
        guard CGPreflightPostEventAccess() else { throw Failure.permission }
        try AgentRunner.post(keyCode: UInt16(kVK_F11), flags: [.maskSecondaryFn], pid: nil)
    }

    static func changeVolume(up: Bool) throws {
        guard CGPreflightPostEventAccess() else { throw Failure.permission }
        let code = up ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        for state in [NX_KEYDOWN, NX_KEYUP] {
            let flags = Int(state) << 8
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                                           data1: (Int(code) << 16) | flags, data2: -1)
            guard let cgEvent = event?.cgEvent else { throw AgentRunner.Failure.unsupportedAction }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    static func openAppleMenu() throws {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let bar = Accessibility.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
              let menu = Accessibility.children(bar).first,
              Accessibility.string(menu, kAXRoleAttribute) == kAXMenuBarItemRole,
              ["Apple", "Apple menu", "苹果", "苹果菜单", "Apple 菜单", "Apple 選單", ""].contains(
                Accessibility.string(menu, kAXTitleAttribute) ?? ""
              ),
              Accessibility.press(menu) else { throw Failure.appleMenuUnavailable }
    }
}

extension SystemHotKey {
    @MainActor
    var label: String {
        let flags = CGEventFlags(rawValue: self.flags)
        let modifiers = (flags.contains(.maskSecondaryFn) ? "fn " : "")
            + (flags.contains(.maskControl) ? "⌃" : "")
            + (flags.contains(.maskAlternate) ? "⌥" : "")
            + (flags.contains(.maskShift) ? "⇧" : "")
            + (flags.contains(.maskCommand) ? "⌘" : "")
        let special: [UInt16: String] = [
            36: "↵", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 115: "↖", 116: "⇞",
            117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let function = functionCodes.firstIndex(of: keyCode).map { "F\($0 + 1)" }
        return modifiers + (special[keyCode] ?? function ?? translatedKey ?? "键码 \(keyCode)")
    }

    @MainActor
    private var translatedKey: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(decoding: chars.prefix(length), as: UTF16.self).uppercased()
    }
}
