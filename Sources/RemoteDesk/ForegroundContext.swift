import AppKit
import ApplicationServices

@MainActor
struct ForegroundContext {
    let bundleID: String
    let pid: pid_t
    var window: AXUIElement?

    static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        let window: AXUIElement?
        if AXIsProcessTrusted() {
            window = Accessibility.element(element, kAXFocusedWindowAttribute)
                ?? (id == "com.apple.finder" ? Accessibility.element(element, kAXMainWindowAttribute) : nil)
        } else {
            window = nil
        }
        return Self(bundleID: id, pid: app.processIdentifier, window: window)
    }

    func matches(_ other: Self?) -> Bool {
        guard let other, pid == other.pid, bundleID == other.bundleID else { return false }
        switch (window, other.window) {
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        case (nil, nil): return true
        default: return false
        }
    }
}

/// The runtime also rechecks the current window before delivering deferred input.
@MainActor
final class ForegroundObserver {
    private var activation: NSObjectProtocol?
    private var windowObserver: AXObserver?
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationChanged() }
        }
        observeWindow()
    }

    func observeWindow() {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = nil
        guard AXIsProcessTrusted(), let current = NSWorkspace.shared.frontmostApplication else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(current.processIdentifier, { _, _, _, pointer in
            guard let pointer else { return }
            let owner = Unmanaged<ForegroundObserver>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { owner.changed() }
        }, &observer)
        guard result == .success, let observer,
              AXObserverAddNotification(observer, AXUIElementCreateApplication(current.processIdentifier),
                                        kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        windowObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func applicationChanged() {
        changed()
        observeWindow()
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = nil
    }
}
