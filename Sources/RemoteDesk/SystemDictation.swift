import AppKit
import ApplicationServices

@MainActor
enum SystemDictation {
    static let setupInstructions = "在系统设置的「键盘」中开启听写。将光标放进输入框，再按一下遥控器语音键。"
    static let remoteMicrophoneInstructions = "在系统「键盘」设置中开启听写，并将麦克风来源设为 BlackHole 2ch。在输入框里按住遥控器语音键说话。"

    enum Failure: LocalizedError {
        case permission, textInputRequired, unavailable, focusChanged, requestUnconfirmed

        var errorDescription: String? {
            switch self {
            case .permission: L10n.tr("此动作需要「辅助功能」权限。")
            case .textInputRequired: L10n.tr("请将光标放进可编辑的文本框，再按语音键。")
            case .unavailable: L10n.tr("当前无法启动系统听写。请确认听写已开启。若此应用没有「开始听写」菜单，可使用快捷键兼容模式。")
            case .focusChanged: L10n.tr("输入焦点已变化，已取消听写。")
            case .requestUnconfirmed: L10n.tr("无法确认系统听写已开始。请检查当前应用的「编辑」菜单。")
            }
        }
    }

    static func start(in context: ForegroundContext) throws {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        let app = AXUIElementCreateApplication(context.pid)
        limitTimeout(app)
        guard let focus = Accessibility.element(app, kAXFocusedUIElementAttribute), acceptsTextInput(focus) else {
            throw Failure.textInputRequired
        }
        guard let item = startItem(in: app), Accessibility.canPress(item) else { throw Failure.unavailable }
        guard context.matches(ForegroundContext.current()),
              let currentFocus = Accessibility.element(app, kAXFocusedUIElementAttribute),
              CFEqual(focus, currentFocus),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else { throw Failure.focusChanged }
        // An AX timeout can mean the app is already handling the request. Do not retry or send a shortcut.
        guard Accessibility.press(item) else { throw Failure.requestUnconfirmed }
    }

    static func openKeyboardSettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"), workspace.open(url) {
            return
        }
        if let settings = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.open(settings)
        }
    }

    private static func acceptsTextInput(_ element: AXUIElement) -> Bool {
        limitTimeout(element)
        let role = Accessibility.string(element, kAXRoleAttribute)
        guard role != kAXSecureTextFieldSubrole,
              Accessibility.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              Accessibility.value(element, kAXEnabledAttribute) as? Bool != false else { return false }
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func startItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = Accessibility.element(app, kAXMenuBarAttribute) else { return nil }
        limitTimeout(bar)
        let deadline = ContinuousClock.now + .milliseconds(300)
        let menus = Accessibility.children(bar)
        var editMenu: AXUIElement?
        for menu in menus {
            guard ContinuousClock.now < deadline else { return nil }
            limitTimeout(menu)
            if ["Edit", "编辑", "編輯"].contains(Accessibility.string(menu, kAXTitleAttribute) ?? "") {
                editMenu = menu
                break
            }
        }

        // Prefer the AppKit identifier observed in TextEdit and Chromium. Older apps can
        // expose only the localized title, so allow an exact, unique match inside Edit.
        let roots = editMenu.map { [$0] } ?? menus
        var titleMatches: [AXUIElement] = []
        for root in roots {
            guard ContinuousClock.now < deadline else { return nil }
            for menu in Accessibility.children(root) {
                limitTimeout(menu)
                for item in Accessibility.children(menu) {
                    guard ContinuousClock.now < deadline else { return nil }
                    limitTimeout(item)
                    let identifier = Accessibility.string(item, kAXIdentifierAttribute)
                    if identifier == "startDictation:", Accessibility.string(item, kAXRoleAttribute) == kAXMenuItemRole {
                        return item
                    }
                    guard editMenu != nil, identifier?.isEmpty != false,
                          let title = Accessibility.string(item, kAXTitleAttribute),
                          ["Start Dictation", "开始听写", "開始聽寫"].contains(title.trimmingCharacters(in: .init(charactersIn: ".…⋯ "))),
                          Accessibility.string(item, kAXRoleAttribute) == kAXMenuItemRole else { continue }
                    titleMatches.append(item)
                }
            }
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private static func limitTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0.1)
    }
}
