import AppKit
import Carbon
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
        } else if model.isDiagnosing || model.learning != nil {
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
        Button(windows.isWorkspaceVisible ? "隐藏工作台" : "显示工作台") {
            windows.setWorkspaceVisible(!windows.isWorkspaceVisible)
        }
        Button(windows.isRemoteModelVisible ? "隐藏遥控器模型" : "显示遥控器模型") {
            windows.toggleRemoteModel()
        }
        Toggle("响应遥控器", isOn: $model.isEnabled)
        Divider()
        if let dictationStatus = model.dictation.phase.message {
            Text(dictationStatus)
        }
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
    private let mediaSettings = MediaSettings()
    private let mediaLauncher = MediaLauncher()
    private(set) var isWorkspaceVisible = false
    private(set) var isRemoteModelVisible = false
    private var isRemoteAlwaysOnTop = UserDefaults.standard.bool(forKey: RemoteWindows.remoteAlwaysOnTopKey) {
        didSet {
            UserDefaults.standard.set(isRemoteAlwaysOnTop, forKey: Self.remoteAlwaysOnTopKey)
            remote?.level = remoteWindowLevel
        }
    }
    private var remote: NSWindow?
    private var remoteMenuKeyMonitor: Any?
    private var configuration: NSWindow?
    private var isTerminating = false
    private static let workspaceVisibilityKey = "RemoteDesk.workspaceVisible"
    private static let remoteModelVisibilityKey = "RemoteDesk.remoteModelVisible"
    private static let remoteAlwaysOnTopKey = "RemoteDesk.remoteAlwaysOnTop"
    private var diagnostics: NSWindow?

    private var remoteWindowLevel: NSWindow.Level { isRemoteAlwaysOnTop ? .floating : .normal }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: nil),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        model.onModelChanged = { [weak self] in self?.resizeRemoteForModel() }
        model.onShowMedia = { [weak self] in self?.showMedia() }
        model.onSwitchApps = { [weak self] in self?.mediaLauncher.showRunningApps() }
        model.onMediaKey = { [weak self] slot, keyboard in
            self?.mediaLauncher.routeRemoteKey(slot, nativeKeyboard: keyboard) ?? false
        }
        model.onDismissMedia = { [weak self] in self?.mediaLauncher.dismiss() }
        mediaLauncher.onError = { [weak self] message in self?.model.reportError(message) }
        remoteMenuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard Int(event.keyCode) == kVK_ContextualMenu,
                  let self, let remote = self.remote, event.window === remote,
                  self.model.isEnabled, self.model.canReadKeys,
                  self.model.remoteDefinition.id == RemoteDefinition.xiaomiID else { return event }
            // RC003's Menu key also arrives through HID. Let that path own the
            // action instead of opening the model's SwiftUI context menu.
            return nil
        }
        model.refreshPermissions()
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.workspaceVisibilityKey: true, Self.remoteModelVisibilityKey: true])
        let showModel = defaults.bool(forKey: Self.remoteModelVisibilityKey)
        if defaults.bool(forKey: Self.workspaceVisibilityKey) { setWorkspaceVisible(true) }
        if showModel { setRemoteModelVisible(true) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions()
    }

    func applicationDidHide(_ notification: Notification) {
        updateWorkspaceVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateWorkspaceVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let remoteMenuKeyMonitor { NSEvent.removeMonitor(remoteMenuKeyMonitor) }
        mediaLauncher.dismiss()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        guard DisplayToggle.shared.needsRestoreOnQuit else { return .terminateNow }
        Task {
            await DisplayToggle.shared.restoreOnQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setWorkspaceVisible(true)
        return false
    }

    func setWorkspaceVisible(_ visible: Bool) {
        guard visible else {
            UserDefaults.standard.set(false, forKey: Self.workspaceVisibilityKey)
            configuration?.close()
            return
        }
        let window = configurationWindow()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if isRemoteModelVisible { layoutRemote(nextTo: window, fitToScreen: true) }
        present(window)
        updateWorkspaceVisibility()
        UserDefaults.standard.set(true, forKey: Self.workspaceVisibilityKey)
        updateRemoteAttachment()
    }

    func toggleRemoteModel() {
        setRemoteModelVisible(!isRemoteModelVisible)
    }

    private func setRemoteModelVisible(_ visible: Bool) {
        isRemoteModelVisible = visible
        UserDefaults.standard.set(isRemoteModelVisible, forKey: Self.remoteModelVisibilityKey)
        if visible {
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate()
        }
        updateRemoteAttachment()
    }

    private func updateWorkspaceVisibility() {
        isWorkspaceVisible = configuration?.isVisible == true && configuration?.isMiniaturized == false && !NSApp.isHidden
    }

    private func updateRemoteAttachment() {
        guard isRemoteModelVisible else {
            if let remote {
                remote.parent?.removeChildWindow(remote)
                remote.orderOut(nil)
            }
            return
        }
        let panel = remoteWindow()
        if let configuration, isWorkspaceVisible {
            layoutRemote(nextTo: configuration, fitToScreen: panel.parent !== configuration)
            panel.isMovable = false
            if panel.parent !== configuration { configuration.addChildWindow(panel, ordered: .above) }
        } else {
            panel.parent?.removeChildWindow(panel)
            panel.isMovable = true
        }
        panel.level = remoteWindowLevel
        panel.orderFront(nil)
    }

    private func showMedia() {
        model.cancelGestures()
        mediaLauncher.show(mediaSettings.selection())
    }

    private func layoutRemote(nextTo workspace: NSWindow, fitToScreen: Bool) {
        let panel = remoteWindow()
        var frame = workspace.frame
        let screen = (workspace.screen ?? NSScreen.main)?.visibleFrame
        let height = min(LiveRemoteView.preferredHeight, frame.height)
        let preferredWidth = remotePanelWidth(for: height)
        var width = preferredWidth
        if let screen {
            let minimum = workspace.minSize.width
            width = min(preferredWidth, max(100, screen.width - minimum))
            if fitToScreen {
                frame.size.width = min(frame.width, max(minimum, screen.width - width))
                frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width - width))
                if frame != workspace.frame { workspace.setFrame(frame, display: true) }
            } else {
                width = min(width, max(100, screen.maxX - frame.maxX))
            }
        }
        panel.setFrame(NSRect(x: frame.maxX, y: frame.maxY - height, width: width, height: height),
                       display: panel.isVisible)
    }

    private func remoteWindow() -> NSWindow {
        if let remote { return remote }
        let window = BorderlessRemoteWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.title = "遥控器"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in self?.setRemoteModelVisible(false) }
        let hosting = NSHostingController(rootView: LiveRemoteView(
            model: model, workspaceVisible: { [weak self] in self?.isWorkspaceVisible == true },
            toggleWorkspace: { [weak self] in
                guard let self else { return }
                self.setWorkspaceVisible(!self.isWorkspaceVisible)
            }, isAlwaysOnTop: Binding(
                get: { [weak self] in self?.isRemoteAlwaysOnTop == true },
                set: { [weak self] in self?.isRemoteAlwaysOnTop = $0 }
            ), hideModel: { [weak self] in self?.setRemoteModelVisible(false) },
            confirmQuit: { [weak self] in self?.confirmQuitFromRemote() }
        ))
        // The device artwork measures the space it receives; AppKit sets the window size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        let height = min(LiveRemoteView.preferredHeight, (NSScreen.main?.visibleFrame.height ?? 780) - 30)
        window.setContentSize(NSSize(width: remotePanelWidth(for: height), height: height))
        window.center()
        remote = window
        return window
    }

    private func confirmQuitFromRemote() {
        let alert = NSAlert()
        alert.messageText = "退出 RemoteDesk？"
        alert.informativeText = model.hasConfigurationChanges
            ? "退出后将停止监听遥控器，未保存的配置更改也会丢失。"
            : "退出后将停止监听遥控器。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1B}"
        alert.addButton(withTitle: "退出").hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }

    private func configurationWindow() -> NSWindow {
        if let configuration { return configuration }
        let window = titledWindow("配置工作台", size: Workspace.initialSize,
                                  extraStyle: .fullSizeContentView,
                                  content: Workspace(model: model, mediaSettings: mediaSettings,
                                                     remoteModelButton: RemoteModelButton(windows: self)) { [weak self] in
                                      self?.showMedia()
                                  })
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.contentMinSize = Workspace.minimumSize
        // Use the native zoom button so the paired windows can stay side by side.
        window.collectionBehavior.insert(.fullScreenNone)
        configuration = window
        return window
    }

    func showDiagnostics() {
        if diagnostics == nil {
            diagnostics = titledWindow("按键诊断", size: NSSize(width: 540, height: 450),
                                       content: SignalDiagnostics(model: model) { [weak self] in self?.diagnostics?.close() })
        }
        model.setDiagnosing(true)
        present(diagnostics)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === configuration, !isTerminating {
            UserDefaults.standard.set(false, forKey: Self.workspaceVisibilityKey)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === diagnostics {
            model.setDiagnosing(false)
            diagnostics = nil
        }
        if notification.object as? NSWindow === configuration, !isTerminating {
            model.cancelLearning()
            isWorkspaceVisible = false
            updateRemoteAttachment()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === configuration else { return }
        updateWorkspaceVisibility()
        updateRemoteAttachment()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === configuration else { return }
        updateWorkspaceVisibility()
        updateRemoteAttachment()
    }

    func windowDidResize(_ notification: Notification) {
        guard let configuration, notification.object as? NSWindow === configuration,
              remote?.parent === configuration else { return }
        layoutRemote(nextTo: configuration, fitToScreen: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let configuration, notification.object as? NSWindow === configuration,
              remote?.parent === configuration else { return }
        layoutRemote(nextTo: configuration, fitToScreen: true)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let configuration, notification.object as? NSWindow === configuration,
              remote?.parent === configuration else { return }
        layoutRemote(nextTo: configuration, fitToScreen: true)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard window === configuration, isRemoteModelVisible else { return defaultFrame }
        let reservedWidth = remotePanelWidth(for: min(LiveRemoteView.preferredHeight, defaultFrame.height))
        var frame = defaultFrame
        frame.size.width = max(window.minSize.width, defaultFrame.width - reservedWidth)
        return frame
    }

    private func remotePanelWidth(for height: CGFloat) -> CGFloat {
        max(160, (height * model.remoteDefinition.layout.bodyRatio + 8).rounded())
    }

    private func resizeRemoteForModel() {
        guard let remote else { return }
        if let configuration, remote.parent === configuration {
            layoutRemote(nextTo: configuration, fitToScreen: true)
        } else {
            var frame = remote.frame
            frame.size.width = min(remotePanelWidth(for: frame.height), remote.screen?.visibleFrame.width ?? 700)
            if let visible = remote.screen?.visibleFrame {
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            }
            remote.setFrame(frame, display: remote.isVisible)
        }
    }

    private func titledWindow<Content: View>(_ title: String, size: NSSize,
                                            extraStyle: NSWindow.StyleMask = [], content: Content) -> NSWindow {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style.union(extraStyle), backing: .buffered, defer: false)
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
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct RemoteModelButton: View {
    unowned let windows: RemoteWindows

    var body: some View {
        let visible = windows.isRemoteModelVisible
        let title = visible ? "隐藏遥控器模型" : "显示遥控器模型"
        Button(action: windows.toggleRemoteModel) {
            Image(systemName: visible ? "appletvremote.gen4.fill" : "appletvremote.gen4")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(visible ? Color.accentColor : .secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
