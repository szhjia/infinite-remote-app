import AppKit
import ApplicationServices
import Carbon
import RemoteCore

@MainActor
final class FinderNavigation {
    enum Failure: LocalizedError {
        case noSelection, noSidebar, unavailable

        var errorDescription: String? {
            switch self {
            case .noSelection: L10n.tr("请先选择一个访达项目。")
            case .noSidebar: L10n.tr("当前访达窗口没有显示边栏。")
            case .unavailable: L10n.tr("当前访达视图无法执行此操作。")
            }
        }
    }

    private struct Browser {
        let window: AXUIElement
        let content: AXUIElement
        let contentArea: AXUIElement
        let sidebar: AXUIElement?
        let sidebarArea: AXUIElement?
        let isList: Bool
    }

    private var sidebarRow: AXUIElement?
    private var highlight: NSPanel?
    private var sidebarInputMonitor: Any?

    func reset() {
        sidebarRow = nil
        highlight?.orderOut(nil)
        if let sidebarInputMonitor { NSEvent.removeMonitor(sidebarInputMonitor) }
        sidebarInputMonitor = nil
    }

    func supports(_ context: ForegroundContext) -> Bool {
        browser(context) != nil
    }

    func run(_ command: FinderCommand, in context: ForegroundContext) throws {
        guard context.matches(.current()) else { return }
        if command == .escape {
            reset()
            try AgentRunner.post(AgentProfile.stop, pid: nil)
            return
        }
        guard let browser = browser(context) else {
            if let key = command.nativeKey { try AgentRunner.post(key, pid: context.pid) }
            return
        }
        let side = sidebarRow
        let app = AXUIElementCreateApplication(context.pid)
        let selected = side ?? selection(in: browser).first
        let focused = Accessibility.element(app, kAXFocusedUIElementAttribute)
        let menuOpen = focused.map(isInsideMenu) == true || [app, browser.content, selected].compactMap { $0 }.contains {
            Accessibility.element($0, kAXShownMenuUIElementAttribute) != nil
        }
        if menuOpen {
            if let key = command.nativeKey { try AgentRunner.post(key, pid: context.pid) }
            return
        }
        switch command {
        case .sidebar:
            guard let sidebar = browser.sidebar, let area = browser.sidebarArea else { throw Failure.noSidebar }
            let rows = sidebarRows(sidebar)
            guard let row = rows.first(where: { Accessibility.value($0, kAXSelectedAttribute) as? Bool == true })
                ?? rows.first(where: { isVisible($0, in: area) }) else { throw Failure.noSidebar }
            try mark(row, in: area)
        case .content:
            reset()
            if let row = selection(in: browser).first ?? items(in: browser).first {
                try select(row, in: browser, pid: context.pid)
            }
        case .up, .down, .left, .right:
            if let side, let sidebar = browser.sidebar, let area = browser.sidebarArea {
                let rows = sidebarRows(sidebar)
                guard let index = rows.firstIndex(where: { CFEqual(side, $0) }) else { reset(); return }
                if command == .up || command == .down {
                    let next = index + (command == .up ? -1 : 1)
                    if rows.indices.contains(next) { try mark(rows[next], in: area) }
                } else {
                    _ = action(command == .left ? "AXCollapse" : "AXExpand", on: side)
                }
            } else if let key = command.nativeKey {
                try AgentRunner.post(key, pid: context.pid)
            }
        case .pageUp, .pageDown:
            let delta = command == .pageDown ? 1 : -1
            if let side, let sidebar = browser.sidebar, let area = browser.sidebarArea {
                let rows = sidebarRows(sidebar)
                if let row = page(from: side, in: rows, container: sidebar, area: area, delta: delta) {
                    reveal(row, in: rows, area: area)
                    try mark(row, in: area)
                }
            } else {
                let rows = items(in: browser)
                if let row = page(from: selected, in: rows, container: browser.content,
                                  area: browser.contentArea, delta: delta) {
                    reveal(row, in: rows, area: browser.contentArea)
                    try select(row, in: browser, pid: context.pid)
                }
            }
        case .open:
            if let side, let area = browser.sidebarArea {
                try click(side, in: area, button: .left, context: context)
                reset()
            } else if !selection(in: browser).isEmpty {
                try AgentRunner.post(keyCode: UInt16(kVK_ANSI_O), flags: .maskCommand, pid: context.pid)
            } else { throw Failure.noSelection }
        case .contextMenu:
            guard let selected else { throw Failure.noSelection }
            if action(kAXShowMenuAction, on: selected) { return }
            guard let area = side == nil ? browser.contentArea : browser.sidebarArea else { throw Failure.unavailable }
            try click(selected, in: area, button: .right, context: context)
        case .parent, .historyBack:
            reset()
            try AgentRunner.post(keyCode: UInt16(command == .parent ? kVK_UpArrow : kVK_ANSI_LeftBracket),
                                 flags: .maskCommand, pid: context.pid)
        case .escape:
            break // Handled before examining the current Finder view.
        }
    }

    private func browser(_ context: ForegroundContext) -> Browser? {
        guard context.bundleID == AppTarget.finder.bundleID, let window = context.window else { return nil }
        let app = AXUIElementCreateApplication(context.pid)
        let containers = browserContainers(in: window)
        guard let (area, content) = containers.first(where: { _, child in
            ["ListView", "IconView"].contains(Accessibility.string(child, kAXIdentifierAttribute) ?? "")
        }) else { return nil }
        if let focused = Accessibility.element(app, kAXFocusedUIElementAttribute),
           [kAXTextFieldRole, kAXTextAreaRole, "AXSearchField"].contains(role(focused)) {
            // Finder also exposes selected file names as AXTextFields. They belong
            // to the content view, and only the inline editor has a text range.
            if !isDescendant(focused, of: content)
                || Accessibility.value(focused, kAXSelectedTextRangeAttribute) != nil { return nil }
        }
        let sidebar = containers.first { parent, child in !CFEqual(parent, area) && role(child) == kAXOutlineRole }
        return Browser(window: window, content: content, contentArea: area, sidebar: sidebar?.1,
                       sidebarArea: sidebar?.0, isList: role(content) == kAXOutlineRole || role(content) == kAXTableRole)
    }

    private func browserContainers(in window: AXUIElement) -> [(AXUIElement, AXUIElement)] {
        var containers: [(AXUIElement, AXUIElement)] = []
        func visit(_ parent: AXUIElement, scrollArea: AXUIElement?, depth: Int) {
            guard depth > 0 else { return }
            for child in Accessibility.children(parent) {
                switch role(child) {
                case kAXScrollAreaRole:
                    visit(child, scrollArea: child, depth: depth - 1)
                case kAXSplitGroupRole, kAXGroupRole, kAXUnknownRole:
                    visit(child, scrollArea: scrollArea, depth: depth - 1)
                default:
                    if let scrollArea { containers.append((scrollArea, child)) }
                }
            }
        }
        visit(window, scrollArea: nil, depth: 6)
        return containers
    }

    private func role(_ element: AXUIElement) -> String {
        Accessibility.string(element, kAXRoleAttribute) ?? ""
    }

    private func sidebarRows(_ sidebar: AXUIElement) -> [AXUIElement] {
        let rows = Accessibility.value(sidebar, kAXRowsAttribute) as? [AXUIElement] ?? Accessibility.children(sidebar)
        return rows.filter { role($0) == kAXRowRole }
    }

    private func items(in browser: Browser) -> [AXUIElement] {
        if browser.isList { return sidebarRows(browser.content) }
        // Finder exposes icons beneath section containers on current macOS.
        return Accessibility.children(browser.content).flatMap { child in
            ["AXSection", kAXGroupRole].contains(role(child)) ? Accessibility.children(child) : [child]
        }.filter {
            [kAXImageRole, kAXButtonRole, "AXLayoutItem", "AXCell"].contains(role($0))
        }
    }

    private func selection(in browser: Browser) -> [AXUIElement] {
        let attribute = browser.isList ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
        if let selected = Accessibility.value(browser.content, attribute) as? [AXUIElement], !selected.isEmpty {
            return selected
        }
        return items(in: browser).filter { Accessibility.value($0, kAXSelectedAttribute) as? Bool == true }
    }

    private func select(_ item: AXUIElement, in browser: Browser, pid: pid_t) throws {
        let attribute = browser.isList ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
        if AXUIElementSetAttributeValue(browser.content, attribute as CFString, [item] as CFArray) == .success
            || AXUIElementSetAttributeValue(item, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            _ = AXUIElementSetAttributeValue(browser.content, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = action("AXScrollToVisible", on: item)
            return
        }
        guard let context = ForegroundContext.current(), context.pid == pid,
              let window = context.window, CFEqual(window, browser.window) else { throw Failure.unavailable }
        try click(item, in: browser.contentArea, button: .left, context: context)
    }

    private func page(from selected: AXUIElement?, in rows: [AXUIElement], container: AXUIElement,
                      area: AXUIElement, delta: Int) -> AXUIElement? {
        guard !rows.isEmpty else { return nil }
        let selectedIndex = selected.flatMap { item in rows.firstIndex(where: { CFEqual($0, item) }) }
        let visible: [AXUIElement]
        if let exposed = Accessibility.value(container, kAXVisibleRowsAttribute) as? [AXUIElement], !exposed.isEmpty {
            visible = exposed
        } else {
            let anchor = selectedIndex ?? 0
            visible = rows[max(0, anchor - 128)..<min(rows.count, anchor + 129)].filter { isVisible($0, in: area) }
        }
        let index = selectedIndex ?? visible.first.flatMap { item in rows.firstIndex(where: { CFEqual($0, item) }) } ?? 0
        return rows[min(rows.count - 1, max(0, index + delta * max(1, visible.count)))]
    }

    private func reveal(_ item: AXUIElement, in rows: [AXUIElement], area: AXUIElement) {
        guard !isVisible(item, in: area), !action("AXScrollToVisible", on: item),
              let bar = Accessibility.element(area, kAXVerticalScrollBarAttribute),
              let index = rows.firstIndex(where: { CFEqual($0, item) }) else { return }
        let position = Double(index) / Double(max(1, rows.count - 1))
        _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: position))
    }

    private func mark(_ row: AXUIElement, in area: AXUIElement) throws {
        _ = action("AXScrollToVisible", on: row)
        guard let rowRect = frame(row), let areaRect = frame(area) else { throw Failure.unavailable }
        let visible = rowRect.intersection(areaRect)
        guard !visible.isEmpty, let primary = NSScreen.screens.first else { throw Failure.unavailable }
        let panel = highlight ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        if highlight == nil {
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.hasShadow = false
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
            panel.contentView?.layer?.borderWidth = 2
            panel.contentView?.layer?.cornerRadius = 5
            highlight = panel
        }
        sidebarRow = row
        if sidebarInputMonitor == nil {
            sidebarInputMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                guard !AgentRunner.isRemoteEvent(event.cgEvent) else { return }
                self?.reset()
            }
        }
        panel.setFrame(NSRect(x: visible.minX, y: primary.frame.maxY - visible.maxY,
                              width: visible.width, height: visible.height), display: true)
        panel.orderFrontRegardless()
    }

    private func click(_ item: AXUIElement, in area: AXUIElement, button: CGMouseButton,
                       context: ForegroundContext) throws {
        guard context.matches(.current()), let itemFrame = frame(item), let areaFrame = frame(area) else {
            throw Failure.unavailable
        }
        let visible = itemFrame.intersection(areaFrame)
        guard !visible.isEmpty else { throw Failure.unavailable }
        let point = CGPoint(x: visible.midX, y: visible.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, isDescendant(hit, of: item),
              let down = CGEvent(mouseEventSource: nil, mouseType: button == .right ? .rightMouseDown : .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: button == .right ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: button) else { throw Failure.unavailable }
        AgentRunner.postRemoteEvent(down, pid: nil)
        AgentRunner.postRemoteEvent(up, pid: nil)
    }

    private func isDescendant(_ element: AXUIElement, of parent: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { return false }
            if CFEqual(node, parent) { return true }
            current = Accessibility.element(node, kAXParentAttribute)
        }
        return false
    }

    private func isInsideMenu(_ element: AXUIElement) -> Bool {
        [kAXMenuRole, kAXMenuItemRole].contains(role(element))
    }

    private func action(_ name: String, on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, name as CFString) == .success
    }

    private func isVisible(_ element: AXUIElement, in area: AXUIElement) -> Bool {
        guard let rect = frame(element), let viewport = frame(area) else { return false }
        return rect.intersects(viewport)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        func read<T>(_ attribute: String, type: AXValueType, into output: inout T) -> Bool {
            guard let raw = Accessibility.value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            return withUnsafeMutablePointer(to: &output) { AXValueGetValue(raw as! AXValue, type, $0) }
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard read(kAXPositionAttribute, type: .cgPoint, into: &point),
              read(kAXSizeAttribute, type: .cgSize, into: &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
}

extension FinderCommand {
    var nativeKey: KeyboardShortcut? {
        let keys: [Self: String] = [.up: "up", .down: "down", .left: "left", .right: "right",
                                    .open: "ok", .parent: "back"]
        guard let slot = keys[self], case let .foregroundKey(shortcut) = AgentProfile.defaults.actions[slot] else { return nil }
        return shortcut
    }
}
