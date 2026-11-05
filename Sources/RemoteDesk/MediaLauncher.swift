import AppKit
import Carbon
import Observation
import RemoteCore
import SwiftUI

@MainActor @Observable
final class MediaLauncher: NSObject, NSWindowDelegate {
    private(set) var apps: [MediaSettings.Installed] = []
    private(set) var focus = 0
    private(set) var tileWidth: CGFloat = 96
    static let tileSpacing: CGFloat = 4
    static let panelPadding: CGFloat = 12
    private var switchesRunningApps = false
    private var panel: LauncherPanel?
    private var lastNativeDismissal: (slot: String, time: ContinuousClock.Instant)?
    var onError: ((String) -> Void)?
    var page: Int { focus / MediaGrid.limit }
    var pageCount: Int { max(1, (apps.count + MediaGrid.limit - 1) / MediaGrid.limit) }
    var pageStart: Int { page * MediaGrid.limit }
    var grid: MediaGrid { MediaGrid(count: apps.count - pageStart, singleRow: !switchesRunningApps) }
    var emptyMessage: String {
        switchesRunningApps ? "没有其他正在运行的应用。" : "请在「系统设置 → 多媒体设置」中选择应用。"
    }

    func showRunningApps() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var seen = Set<String>()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { lhs, rhs in
            if lhs.processIdentifier == frontmost { return rhs.processIdentifier != frontmost }
            if rhs.processIdentifier == frontmost { return false }
            return (lhs.localizedName ?? "").localizedStandardCompare(rhs.localizedName ?? "") == .orderedAscending
        }
        let items = running.compactMap { app -> MediaSettings.Installed? in
            guard let id = app.bundleIdentifier, let url = app.bundleURL, seen.insert(id).inserted else { return nil }
            let candidate = MediaSettings.Candidate(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
            return .init(candidate: candidate, url: url, icon: app.icon ?? NSWorkspace.shared.icon(forFile: url.path))
        }
        show(items, switchingApps: true, initialFocus: items.count > 1 && running.first?.processIdentifier == frontmost ? 1 : 0)
    }

    func show(_ apps: [MediaSettings.Installed], switchingApps: Bool = false, initialFocus: Int = 0) {
        self.apps = apps
        switchesRunningApps = switchingApps
        focus = initialFocus
        lastNativeDismissal = nil
        let panel = self.panel ?? makePanel()
        panel.title = switchingApps ? "切换应用" : "媒体应用"
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let spacing = Self.tileSpacing * CGFloat(grid.columns - 1)
        let padding = 2 * Self.panelPadding
        let fittingWidth = (frame.width - 24 - padding - spacing) / CGFloat(grid.columns)
        tileWidth = min(96, max(1, floor(fittingWidth)))
        let size = apps.isEmpty ? NSSize(width: 320, height: 84)
            : NSSize(width: tileWidth * CGFloat(grid.columns) + spacing + padding,
                     height: CGFloat(grid.rows * 98 + (pageCount > 1 ? 48 : 26)))
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    func routeRemoteKey(_ slot: String, nativeKeyboard: Bool) -> Bool {
        guard let panel, panel.isVisible else {
            if nativeKeyboard, let recent = lastNativeDismissal, recent.slot == slot,
               recent.time.duration(to: .now) < .milliseconds(120) {
                // The matching HID callback can arrive after the keyboard event closed the panel.
                lastNativeDismissal = nil
                return true
            }
            return false
        }
        // Keyboard HID keys also reach a focused panel as ordinary NSEvents.
        if !nativeKeyboard || !panel.isKeyWindow { handle(slot) }
        return true
    }

    private func handle(_ slot: String) {
        switch slot {
        case "left": move(.left)
        case "right": move(.right)
        case "up": move(.up)
        case "down": move(.down)
        case "ok": open(focus)
        case "next", "previous":
            if !apps.isEmpty {
                let step = slot == "next" ? 1 : -1
                focus = (focus + step + apps.count) % apps.count
            }
        case "tv", "home", "menu", "back": dismiss()
        default: break
        }
    }

    private func move(_ direction: MediaGrid.Direction) {
        guard !apps.isEmpty else { return }
        let local = focus - pageStart
        let next = grid.move(from: local, toward: direction)
        if next != local {
            focus = pageStart + next
        } else if direction == .down, page + 1 < pageCount {
            focus = min(pageStart + MediaGrid.limit + local % grid.columns, apps.count - 1)
        } else if direction == .up, page > 0 {
            focus = pageStart - 3 + local % grid.columns
        }
    }

    fileprivate func open(_ index: Int) {
        guard apps.indices.contains(index) else { return }
        let app = apps[index]
        let mustBeRunning = switchesRunningApps
        dismiss()
        Task {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            do {
                if mustBeRunning,
                   !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).contains(where: { !$0.isTerminated }) {
                    throw CocoaError(.fileNoSuchFile)
                }
                guard let url = AgentRunner.appURL(.init(bundleID: app.id, path: app.url.path)) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
            } catch {
                onError?("无法打开\(app.candidate.name)：\(error.localizedDescription)")
            }
        }
    }

    private func makePanel() -> LauncherPanel {
        let window = LauncherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        window.title = "媒体应用"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.delegate = self
        window.handleKey = { [weak self] slot in
            guard let self else { return }
            self.handle(slot)
            if !windowIsVisible { lastNativeDismissal = (slot, .now) }
        }
        let host = NSHostingController(rootView: LauncherGridView(launcher: self))
        host.sizingOptions = []
        window.contentViewController = host
        panel = window
        return window
    }

    private var windowIsVisible: Bool { panel?.isVisible == true }
}

private final class LauncherPanel: NSPanel {
    var handleKey: ((String) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        let slots = [kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up",
                     kVK_DownArrow: "down", kVK_Return: "ok", kVK_ANSI_KeypadEnter: "ok", kVK_Escape: "back"]
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if Int(event.keyCode) == kVK_Tab {
                handleKey?(event.modifierFlags.contains(.shift) ? "previous" : "next")
                return
            }
            if let slot = slots[Int(event.keyCode)] {
                if slot != "ok" || !event.isARepeat { handleKey?(slot) }
                return
            }
        }
        super.sendEvent(event)
    }
}

private struct LauncherGridView: View {
    unowned let launcher: MediaLauncher

    var body: some View {
        Group {
            if launcher.apps.isEmpty {
                Text(launcher.emptyMessage)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: 6) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(launcher.tileWidth), spacing: MediaLauncher.tileSpacing),
                                               count: launcher.grid.columns),
                              spacing: MediaLauncher.tileSpacing) {
                        ForEach(0..<(launcher.grid.rows * launcher.grid.columns), id: \.self) { offset in
                            let index = launcher.pageStart + offset
                            if launcher.apps.indices.contains(index) {
                                tile(launcher.apps[index], index: index)
                            } else {
                                Color.clear.frame(height: 94).accessibilityHidden(true)
                            }
                        }
                    }
                    if launcher.pageCount > 1 {
                        Text("\(launcher.page + 1) / \(launcher.pageCount)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(MediaLauncher.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SwitcherBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18)).allowsHitTesting(false))
        .foregroundStyle(.white)
    }

    private func tile(_ app: MediaSettings.Installed, index: Int) -> some View {
        let selected = launcher.focus == index
        let iconSize = min(58, max(1, launcher.tileWidth - 12))
        return Button { launcher.open(index) } label: {
            VStack(spacing: 3) {
                Image(nsImage: app.icon).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize).accessibilityHidden(true)
                Text(app.candidate.name).font(.caption)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 94)
            .background(selected ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SwitcherBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
