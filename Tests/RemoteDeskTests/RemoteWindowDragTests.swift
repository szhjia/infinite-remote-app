import AppKit
import SwiftUI
import Testing
@testable import RemoteDesk

@Test @MainActor
func draggingDockedRemoteMovesBothWindows() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = fixtureRemoteModel(hid: HIDMonitor(), storeURL: directory.appending(path: "configuration.json"),
                                   runAction: { _, _ in })
    let workspace = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                             styleMask: [.titled], backing: .buffered, defer: false)
    let remote = NSWindow(contentRect: NSRect(x: 500, y: 100, width: 160, height: LiveRemoteView.preferredHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    workspace.isReleasedWhenClosed = false
    remote.isReleasedWhenClosed = false
    defer {
        workspace.removeChildWindow(remote)
        remote.close()
        workspace.close()
    }
    remote.isMovable = false
    let host = NSHostingView(rootView: LiveRemoteView(
        model: model, showWorkspace: {},
        isAlwaysOnTop: .constant(false), hideModel: {}, confirmQuit: {}
    ))
    remote.contentView = host
    workspace.addChildWindow(remote, ordered: .above)
    remote.setFrameTopLeftPoint(NSPoint(x: workspace.frame.maxX, y: workspace.frame.maxY))
    host.layoutSubtreeIfNeeded()

    let workspaceOrigin = workspace.frame.origin
    let remoteOrigin = remote.frame.origin
    let start = NSPoint(x: 60, y: 85)
    let end = NSPoint(x: 102, y: 112)
    let casing = try #require(host.hitTest(start))
    let down = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
        windowNumber: remote.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    let drag = try #require(NSEvent.mouseEvent(
        with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 0,
        windowNumber: remote.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))

    casing.mouseDown(with: down)
    casing.mouseDragged(with: drag)

    #expect(workspace.frame.origin == NSPoint(x: workspaceOrigin.x + 42, y: workspaceOrigin.y + 27))
    #expect(remote.frame.origin == NSPoint(x: remoteOrigin.x + 42, y: remoteOrigin.y + 27))
}
