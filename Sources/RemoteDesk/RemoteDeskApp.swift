import AppKit
import Observation
import SwiftUI

@main
struct RemoteDeskApp: App {
    @NSApplicationDelegateAdaptor(RemoteWindows.self) private var windows

    var body: some Scene {
        let status = trayStatus
        MenuBarExtra {
            TrayMenu(model: windows.model, windows: windows)
        } label: {
            Image(status.asset, bundle: .module)
                .accessibilityLabel(status.description)
        }
    }

    private var trayStatus: (asset: String, description: String) {
        let model = windows.model
        return if !model.isEnabled {
            ("BridgePaused", "遥控台 · 已暂停")
        } else if !model.canReadKeys {
            ("BridgeIdle", "遥控台 · 未监听")
        } else if model.isDiagnosing || model.isEditing || model.learning != nil {
            ("BridgePaused", "遥控台 · 暂停触发")
        } else {
            ("BridgeListening", "遥控台 · 正在监听")
        }
    }
}

private struct TrayMenu: View {
    @Bindable var model: RemoteModel
    let windows: RemoteWindows

    var body: some View {
        Toggle("显示遥控器", isOn: Binding(
            get: { windows.isRemoteVisible },
            set: { windows.setRemoteVisible($0) }
        ))
        Toggle("响应遥控器", isOn: $model.isEnabled)
        Divider()
        Menu("切换 Agent · \(model.profile?.name ?? "未选择")") {
            ForEach(model.config.agents) { profile in
                Button {
                    model.selectAgent(profile.id)
                } label: {
                    if model.profile?.id == profile.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        }
        Button("打开配置…") { windows.showConfiguration() }
        Button {
            windows.showDiagnostics()
        } label: {
            Label {
                Text("按键诊断…")
            } icon: {
                Image("BridgeDiagnostics", bundle: .module)
            }
        }
        Divider()
        Button("退出遥控台") { NSApp.terminate(nil) }
    }
}

@MainActor @Observable
final class RemoteWindows: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = RemoteModel()
    private(set) var isRemoteVisible = false
    private var remote: NSWindow?
    private var configuration: NSWindow?
    private var diagnostics: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: nil),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        model.refreshPermissions()
        showRemote()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions()
    }

    func applicationDidHide(_ notification: Notification) {
        syncRemoteVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        syncRemoteVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRemote()
        return true
    }

    func showRemote() {
        if remote == nil {
            let preferredSize = NSSize(width: 352, height: 800)
            let visibleHeight = NSScreen.main?.visibleFrame.height ?? preferredSize.height + 24
            let height = min(preferredSize.height, max(1, visibleHeight - 24))
            let width = max(272, (preferredSize.width * height / preferredSize.height).rounded())
            let window = BorderlessRemoteWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.title = "遥控器"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            window.onOrderOut = { [weak self] in self?.syncRemoteVisibility() }
            let hosting = NSHostingController(
                rootView: LiveRemoteView(model: model, openConfiguration: { [weak self] in self?.showConfiguration() })
            )
            // Keep AppKit in charge of sizing the borderless window. The device view
            // measures the space it receives and has no intrinsic window size.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
            remote = window
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        present(remote)
        syncRemoteVisibility()
    }

    func setRemoteVisible(_ isVisible: Bool) {
        if isVisible {
            showRemote()
        } else {
            remote?.orderOut(nil)
        }
    }

    private func syncRemoteVisibility() {
        isRemoteVisible = remote?.isVisible == true && !NSApp.isHidden
    }

    func showConfiguration() {
        if configuration == nil {
            configuration = titledWindow("遥控台 · 配置", size: NSSize(width: 1020, height: 720),
                                         content: Workspace(model: model).frame(minWidth: 890, minHeight: 640))
        }
        present(configuration)
    }

    func showDiagnostics() {
        if diagnostics == nil {
            diagnostics = titledWindow("按键诊断", size: NSSize(width: 540, height: 450),
                                       content: SignalDiagnostics(model: model) { [weak self] in self?.diagnostics?.close() })
        }
        model.setDiagnosing(true)
        present(diagnostics)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === remote {
            isRemoteVisible = false
        }
        if notification.object as? NSWindow === diagnostics {
            model.setDiagnosing(false)
            diagnostics = nil
        }
        if notification.object as? NSWindow === configuration {
            model.cancelLearning()
            model.isEditing = false
            configuration = nil
        }
    }

    private func titledWindow<Content: View>(_ title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class BorderlessRemoteWindow: NSWindow {
    var onOrderOut: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onOrderOut?()
    }

    override func cancelOperation(_ sender: Any?) { orderOut(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
