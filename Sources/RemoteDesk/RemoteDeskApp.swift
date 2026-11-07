import AppKit
import Carbon
#if DEBUG
import Darwin
#endif
import Observation
import SwiftUI

@main
enum RemoteDeskMain {
    @MainActor
    static func main() {
        #if DEBUG
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinite-remote-debug.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            FileHandle.standardError.write(Data("Cannot open the Infinite Remote Debug lock.\n".utf8))
            return
        }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let message = errno == EWOULDBLOCK
                ? "Infinite Remote Debug is already running."
                : "Cannot acquire the Infinite Remote Debug lock."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return
        }
        #endif
        RemoteDeskApp.main()
    }
}

struct RemoteDeskApp: App {
    @NSApplicationDelegateAdaptor(RemoteWindows.self) private var windows

    var body: some Scene {
        @Bindable var windows = windows
        let status = trayStatus
        let isInserted = windows.isMenuBarItemInserted
        MenuBarExtra(isInserted: Binding(get: { isInserted }, set: { windows.isMenuBarItemInserted = $0 })) {
            TrayMenu(model: windows.model, windows: windows)
        } label: {
            Image(status.asset, bundle: .module)
                .accessibilityLabel(status.description)
        }
        Settings {
            AppSettingsView(model: windows.model, library: windows.resourceLibrary,
                            mediaSettings: windows.mediaSettings, pane: $windows.settingsPane,
                            showSetup: windows.startSetupFromSettings, previewMedia: windows.showMediaPreview)
                .frame(width: 600, height: 410)
        }
    }

    private var trayStatus: (asset: String, description: String) {
        let model = windows.model
        return if !model.isEnabled {
            ("BridgePaused", L10n.tr("无限遥控器 · 已暂停"))
        } else if !model.canReadKeys {
            ("BridgeIdle", L10n.tr("无限遥控器 · 未监听"))
        } else if model.isDiagnosing || model.learning != nil {
            ("BridgePaused", L10n.tr("无限遥控器 · 暂停触发"))
        } else {
            ("BridgeListening", L10n.tr("无限遥控器 · 正在监听"))
        }
    }
}

private struct TrayMenu: View {
    @Bindable var model: RemoteModel
    let windows: RemoteWindows

    var body: some View {
        Text(model.connectionStatus)
        Divider()
        Button(L10n.tr("打开工作台"), action: windows.showWorkspace)
        if windows.needsInitialSetup && windows.didDeferSetup {
            Button(L10n.tr("继续设置遥控器"), action: windows.showSetup)
        }
        Button((windows.isRemoteModelVisible && model.hasRemote) ? L10n.tr("隐藏遥控器模型") : L10n.tr("显示遥控器模型")) {
            windows.toggleRemoteModel()
        }.disabled(!model.hasRemote || windows.needsInitialSetup)
        Toggle(L10n.tr("响应遥控器"), isOn: $model.isEnabled)
        Divider()
        if let dictationStatus = model.dictation.phase.message {
            Text(dictationStatus)
        }
        Button {
            windows.showDiagnostics()
        } label: {
            Label {
                Text(L10n.tr("按键诊断…"))
            } icon: {
                Image("BridgeDiagnostics", bundle: .module)
            }
        }
        SettingsLink { Text(L10n.tr("设置…")) }
        Divider()
        Button(L10n.tr("退出无限遥控器")) { NSApp.terminate(nil) }
    }
}

@MainActor @Observable
final class RemoteWindows: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = RemoteModel()
    let mediaSettings = MediaSettings()
    private let mediaLauncher = MediaLauncher()
    @ObservationIgnored lazy var resourceLibrary = ResourceLibrary(directory: model.libraryDirectory)
    var settingsPane = AppSettingsPane.permissions
    private var setupWindow: NSWindow?
    private var showsSetupKeyboardFocus = false
    private var hasPresentedWorkspace = false
    var isMenuBarItemInserted = false
    private(set) var needsInitialSetup = false
    private(set) var didDeferSetup = false
    private var firstKeyToConfigure: String?
    private var workspacePage: Workspace.Page = .remote {
        didSet { configuration?.title = workspacePage.title }
    }
    private var isWorkspaceVisible = false
    private(set) var isRemoteModelVisible = false
    private var isRemoteAlwaysOnTop = UserDefaults.standard.bool(forKey: RemoteWindows.remoteAlwaysOnTopKey) {
        didSet {
            UserDefaults.standard.set(isRemoteAlwaysOnTop, forKey: Self.remoteAlwaysOnTopKey)
            remote?.level = remoteWindowLevel
        }
    }
    private var remote: NSWindow?
    private var windowEventMonitor: Any?
    private var foregroundObserver: ForegroundObserver?
    private var configuration: NSWindow?
    private var isTerminating = false
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
        foregroundObserver = ForegroundObserver { [weak self] in
            AgentRunner.finder.reset()
            self?.model.foregroundChanged()
        }
        windowEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            if let setupWindow = self.setupWindow, event.window === setupWindow {
                self.updateSetupKeyboardFocus(for: event)
            }
            guard event.type == .keyDown || event.type == .keyUp else { return event }
            guard Int(event.keyCode) == kVK_ContextualMenu,
                  let remote = self.remote, event.window === remote,
                  self.model.isEnabled, self.model.canReadKeys,
                  self.model.consumesContextMenu else { return event }
            // The package declares native Menu handling through HID. Let that path own the
            // action instead of opening the model's SwiftUI context menu.
            return nil
        }
        model.refreshPermissions()
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.remoteModelVisibilityKey: true])
        isRemoteModelVisible = defaults.bool(forKey: Self.remoteModelVisibilityKey)
        needsInitialSetup = SetupStartup.requiresGuide(in: defaults, hasModel: model.hasRemote)
        if needsInitialSetup { SetupStartup.begin(in: defaults) }
        showWorkspace()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions()
        foregroundObserver?.observeWindow()
    }

    func applicationDidHide(_ notification: Notification) {
        updateWorkspaceVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateWorkspaceVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopResponding()
        foregroundObserver?.stop()
        AgentRunner.finder.reset()
        if let windowEventMonitor { NSEvent.removeMonitor(windowEventMonitor) }
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
        showWorkspace()
        return false
    }

    func showWorkspace() {
        if setupWindow != nil || (needsInitialSetup && !didDeferSetup) {
            showSetup()
            return
        }
        let window = configurationWindow()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        present(window)
        updateWorkspaceVisibility()
        if isWorkspaceVisible && !hasPresentedWorkspace {
            hasPresentedWorkspace = true
            isMenuBarItemInserted = true
        }
        updateRemoteAttachment()
    }

    private func toggleWorkspace() {
        updateWorkspaceVisibility()
        if isWorkspaceVisible {
            configuration?.close()
        } else {
            showWorkspace()
        }
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
        guard !needsInitialSetup && isRemoteModelVisible && model.hasRemote else {
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

    func showMediaPreview(_ apps: [MediaSettings.LaunchItem], didClose: @escaping () -> Void) {
        mediaLauncher.show(apps, previewCompletion: didClose)
    }

    private func layoutRemote(nextTo workspace: NSWindow, fitToScreen: Bool) {
        let panel = remoteWindow()
        var frame = workspace.frame
        let screen = (workspace.screen ?? NSScreen.main)?.visibleFrame
        let height = min(LiveRemoteView.preferredHeight, frame.height)
        let preferredWidth = remotePanelWidth(for: height)
        var width = preferredWidth
        if let screen {
            width = min(preferredWidth, max(100, screen.width - frame.width))
            if fitToScreen {
                frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width - width))
                if frame.origin != workspace.frame.origin { workspace.setFrameOrigin(frame.origin) }
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
        window.title = L10n.tr("遥控器")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in self?.setRemoteModelVisible(false) }
        let hosting = NSHostingController(rootView: LiveRemoteView(
            model: model,
            workspaceVisible: { [weak self] in self?.isWorkspaceVisible == true },
            toggleWorkspace: { [weak self] in self?.toggleWorkspace() },
            isAlwaysOnTop: Binding(
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
        alert.messageText = L10n.tr("退出无限遥控器？")
        alert.informativeText = model.hasConfigurationChanges
            ? L10n.tr("退出后将停止监听遥控器，未保存的配置更改也会丢失。")
            : L10n.tr("退出后将停止监听遥控器。")
        alert.addButton(withTitle: L10n.tr("取消")).keyEquivalent = "\u{1B}"
        alert.addButton(withTitle: L10n.tr("退出")).hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }

    private func configurationWindow() -> NSWindow {
        if let configuration { return configuration }
        let window = titledWindow(workspacePage.title, size: Workspace.windowSize,
                                  extraStyle: .fullSizeContentView,
                                  content: Workspace(model: model, library: resourceLibrary,
                                      page: Binding(get: { [weak self] in self?.workspacePage ?? .remote },
                                                    set: { [weak self] in self?.workspacePage = $0 }),
                                      showDiagnostics: { [weak self] in self?.showDiagnostics() },
                                      showSettings: { [weak self] in self?.showSettings($0) },
                                      firstKeyToConfigure: Binding(
                                          get: { [weak self] in self?.firstKeyToConfigure },
                                          set: { [weak self] in self?.firstKeyToConfigure = $0 })))
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        if let lastWindowButton = window.standardWindowButton(.zoomButton) ?? window.standardWindowButton(.miniaturizeButton),
           let titlebar = lastWindowButton.superview {
            let remoteControls = NSHostingView(rootView: WorkspaceRemoteControls(windows: self))
            remoteControls.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(remoteControls)
            NSLayoutConstraint.activate([
                remoteControls.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -15),
                remoteControls.centerYAnchor.constraint(equalTo: lastWindowButton.centerYAnchor)
            ])
            let pageTitle = NSHostingView(rootView: WorkspaceTitle(windows: self))
            pageTitle.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(pageTitle)
            NSLayoutConstraint.activate([
                pageTitle.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor,
                                                   constant: Workspace.sidebarWidth + 25),
                pageTitle.centerYAnchor.constraint(equalTo: lastWindowButton.centerYAnchor)
            ])
        }
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentMinSize = NSSize(width: 890, height: 520)
        configuration = window
        return window
    }

    func startSetupFromSettings() {
        if setupWindow == nil && !needsInitialSetup {
            SetupStartup.begin(in: .standard)
            SetupStartup.save(.welcome, in: .standard)
            needsInitialSetup = true
            didDeferSetup = false
        }
        showSetup()
    }

    func showSetup() {
        if setupWindow == nil {
            showsSetupKeyboardFocus = false
            let window = titledWindow(L10n.tr("遥控器使用引导"), size: SetupGuide.windowSize,
                                      resizable: false, content: SetupGuide(
                                          model: model, library: resourceLibrary,
                                          stage: SetupStartup.stage(in: .standard, hasModel: model.hasRemote),
                                          showsKeyboardFocus: { [weak self] in self?.showsSetupKeyboardFocus ?? false },
                                          saveStage: { SetupStartup.save($0, in: .standard) },
                                          deferSetup: { [weak self] in self?.deferSetup() },
                                          finish: { [weak self] in self?.finishSetup() }))
            window.collectionBehavior.insert(.fullScreenNone)
            setupWindow = window
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if setupWindow?.isMiniaturized == true { setupWindow?.deminiaturize(nil) }
        present(setupWindow)
    }

    private func updateSetupKeyboardFocus(for event: NSEvent) {
        switch event.type {
        case .keyDown:
            let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            if !showsSetupKeyboardFocus && Int(event.keyCode) == kVK_Tab
                && event.modifierFlags.intersection(shortcutModifiers).isEmpty {
                showsSetupKeyboardFocus = true
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            if showsSetupKeyboardFocus { showsSetupKeyboardFocus = false }
        default:
            break
        }
    }

    private func deferSetup() {
        setupWindow?.close()
        didDeferSetup = needsInitialSetup
        showWorkspace()
    }

    private func finishSetup() {
        guard SetupReadiness(model: model).canFinish,
              let key = model.keys.first(where: { $0.id == model.slot }) ?? model.keys.first else { return }
        SetupStartup.finish(in: .standard)
        needsInitialSetup = false
        didDeferSetup = false
        setupWindow?.close()
        workspacePage = .remote
        model.selectSlot(key.id)
        firstKeyToConfigure = key.id
        showWorkspace()
    }

    func showSettings(_ pane: AppSettingsPane? = nil) {
        if let pane { settingsPane = pane }
        // AppKit-hosted workbench views are outside the SwiftUI scene environment.
        // Invoke the Settings scene's existing application menu command.
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        menu.performActionForItem(at: index)
    }

    func showDiagnostics() {
        if diagnostics == nil {
            diagnostics = titledWindow(L10n.tr("按键诊断"), size: NSSize(width: 540, height: 450),
                content: SignalDiagnostics(model: model, showPermissions: { [weak self] in
                    self?.showSettings(.permissions)
                }, showWorkspace: { [weak self] in
                    self?.showWorkspace()
                }, close: { [weak self] in self?.diagnostics?.close() }))
        }
        model.setDiagnosing(true)
        present(diagnostics)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === setupWindow, needsInitialSetup else { return true }
        // The red close button quits the first-run app so reopening can apply new grants.
        // The guide's own actions call close() directly and continue into the workbench.
        NSApp.terminate(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === setupWindow {
            setupWindow = nil
        }
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

    func windowDidChangeScreen(_ notification: Notification) {
        guard let configuration, notification.object as? NSWindow === configuration,
              remote?.parent === configuration else { return }
        layoutRemote(nextTo: configuration, fitToScreen: true)
    }

    private func remotePanelWidth(for height: CGFloat) -> CGFloat {
        max(160, (height * model.remoteDefinition.layout.bodyRatio + 8).rounded())
    }

    private func resizeRemoteForModel() {
        guard let remote else {
            if isRemoteModelVisible && model.hasRemote { updateRemoteAttachment() }
            return
        }
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
                                            extraStyle: NSWindow.StyleMask = [], resizable: Bool = true,
                                            content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
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

private extension RemoteWindows {
    struct WorkspaceRemoteControls: View {
        unowned let windows: RemoteWindows

        var body: some View {
            HStack(spacing: 8) {
                if windows.workspacePage == .remote && windows.model.hasRemote {
                    Label(windows.model.connectionStatus,
                          systemImage: windows.model.canReadKeys ? "waveform" : "exclamationmark.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                RemoteModelButton(windows: windows)
            }
            .fixedSize()
        }
    }

    struct WorkspaceTitle: View {
        unowned let windows: RemoteWindows

        var body: some View {
            Text(windows.workspacePage.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

struct RemoteModelButton: View {
    unowned let windows: RemoteWindows

    var body: some View {
        let visible = windows.isRemoteModelVisible && windows.model.hasRemote
        let title = visible ? L10n.tr("隐藏遥控器模型") : L10n.tr("显示遥控器模型")
        Button(action: windows.toggleRemoteModel) {
            RemoteControlIcon()
                .foregroundStyle(visible ? Color.accentColor : .secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
        .disabled(!windows.model.hasRemote)
    }
}

/// Orbit Remote: native vector artwork on a square canvas.
private struct RemoteControlIcon: View {
    var body: some View {
        ZStack {
            OrbitRemoteOutline()
                .stroke(style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round))
            OrbitRemoteDirections().fill()
        }
        .frame(width: 12, height: 15)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct OrbitRemoteOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The outer shell joins the direction ring above and below the side gaps.
        path.move(to: CGPoint(x: 1, y: 12))
        path.addLine(to: CGPoint(x: 1, y: 8))
        path.addCurve(to: CGPoint(x: 8, y: 1), control1: CGPoint(x: 1, y: 4), control2: CGPoint(x: 4, y: 1))
        path.addLine(to: CGPoint(x: 16, y: 1))
        path.addCurve(to: CGPoint(x: 23, y: 8), control1: CGPoint(x: 20, y: 1), control2: CGPoint(x: 23, y: 4))
        path.addLine(to: CGPoint(x: 23, y: 12))
        path.addCurve(to: CGPoint(x: 1, y: 12), control1: CGPoint(x: 20, y: 2.5), control2: CGPoint(x: 4, y: 2.5))
        path.closeSubpath()

        path.move(to: CGPoint(x: 1, y: 16.5))
        path.addLine(to: CGPoint(x: 1, y: 22))
        path.addCurve(to: CGPoint(x: 8, y: 29), control1: CGPoint(x: 1, y: 26), control2: CGPoint(x: 4, y: 29))
        path.addLine(to: CGPoint(x: 16, y: 29))
        path.addCurve(to: CGPoint(x: 23, y: 22), control1: CGPoint(x: 20, y: 29), control2: CGPoint(x: 23, y: 26))
        path.addLine(to: CGPoint(x: 23, y: 16.5))
        path.addCurve(to: CGPoint(x: 1, y: 16.5), control1: CGPoint(x: 20, y: 26), control2: CGPoint(x: 4, y: 26))
        path.closeSubpath()

        path.move(to: CGPoint(x: 9, y: 25.5))
        path.addLine(to: CGPoint(x: 15, y: 25.5))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 30)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct OrbitRemoteDirections: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for points in [
            [CGPoint(x: 12, y: 7.5), CGPoint(x: 10.3, y: 10), CGPoint(x: 13.7, y: 10)],
            [CGPoint(x: 12, y: 21), CGPoint(x: 10.3, y: 18.5), CGPoint(x: 13.7, y: 18.5)],
            [CGPoint(x: 4.8, y: 14.25), CGPoint(x: 7.3, y: 12.5), CGPoint(x: 7.3, y: 16)],
            [CGPoint(x: 19.2, y: 14.25), CGPoint(x: 16.7, y: 12.5), CGPoint(x: 16.7, y: 16)]
        ] {
            path.addLines(points)
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 30)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
