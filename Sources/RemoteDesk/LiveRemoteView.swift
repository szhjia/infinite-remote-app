import AppKit
import RemoteCore
import SwiftUI

struct LiveRemoteView: View {
    static let preferredHeight = XiaomiBitmap.workspaceWidth * XiaomiBitmap.bodyHeightPerBitmapWidth

    let model: RemoteModel
    let workspaceVisible: () -> Bool
    let toggleWorkspace: () -> Void
    @Binding var isAlwaysOnTop: Bool
    let hideModel: () -> Void
    let confirmQuit: () -> Void

    @State private var hovering = false

    var body: some View {
        DockedRemoteLayout {
            casing
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var casing: some View {
        GeometryReader { geometry in
            let artWidth = geometry.size.width / XiaomiBitmap.bodyWidthFraction
            let artHeight = artWidth * XiaomiBitmap.heightToWidth
            XiaomiArtwork(highlight: { model.pulse == $0 ? .accentColor.opacity(0.50) : .clear },
                          help: help(for:), activate: model.pressVirtualKey)
                .frame(width: artWidth, height: artHeight * XiaomiBitmap.visibleHeightFraction)
                .offset(x: -artWidth * XiaomiBitmap.bodyLeftFraction, y: -artHeight * XiaomiBitmap.bodyTopFraction)
                .disabled(!model.hasConnectedXiaomi)
        }
        .background(RemoteDragSurface())
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 4) {
                    windowButton("minus", title: "隐藏遥控器模型", action: hideModel)
                    windowButton("xmark", title: "退出 RemoteDesk", action: confirmQuit)
                }
                .padding(4)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Text("RemoteDesk · \(model.connectionStatus)")
            Divider()
            Button(workspaceVisible() ? "隐藏工作台" : "显示工作台", action: toggleWorkspace)
            Toggle("窗口置顶", isOn: $isAlwaysOnTop)
        }
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
    }

    private func windowButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 16, height: 16)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func help(for key: RemoteKey) -> String {
        guard let action = model.profile?.actions[key.id] else { return key.name }
        return [key.name, action.title, action.detail].compactMap { $0 }.joined(separator: " · ")
    }

}

private enum XiaomiBitmap {
    static let heightToWidth: CGFloat = 3
    static let visibleHeightFraction: CGFloat = 2107.0 / 2172.0
    static let bodyLeftFraction: CGFloat = 100.0 / 724.0
    static let bodyTopFraction: CGFloat = 106.0 / 2172.0
    static let bodyWidthFraction: CGFloat = 525.0 / 724.0
    static let bodyHeightFraction = visibleHeightFraction - bodyTopFraction
    static let bodyHeightPerBitmapWidth = heightToWidth * bodyHeightFraction
    static let workspaceWidth = XiaomiArtwork.workspaceHeight / (heightToWidth * visibleHeightFraction)
}

private struct DockedRemoteLayout: Layout {
    private let gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let artWidth = min(XiaomiBitmap.workspaceWidth,
                           max(0, bounds.width - gap) / XiaomiBitmap.bodyWidthFraction,
                           bounds.height / XiaomiBitmap.bodyHeightPerBitmapWidth)
        let bodyWidth = artWidth * XiaomiBitmap.bodyWidthFraction
        let bodyHeight = artWidth * XiaomiBitmap.bodyHeightPerBitmapWidth
        subviews[0].place(at: CGPoint(x: bounds.minX + gap, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bodyWidth, height: bodyHeight))
    }
}

private struct RemoteDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var workspaceDragOffset: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            workspaceDragOffset = nil
            guard let window else { return }
            if let workspace = window.parent {
                let pointer = window.convertPoint(toScreen: event.locationInWindow)
                workspaceDragOffset = NSPoint(x: pointer.x - workspace.frame.minX,
                                              y: pointer.y - workspace.frame.minY)
            } else if window.isMovable {
                window.performDrag(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let offset = workspaceDragOffset, let window, let workspace = window.parent else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            workspace.setFrameOrigin(NSPoint(x: pointer.x - offset.x, y: pointer.y - offset.y))
            // Programmatic moves can leave the child at its old screen position.
            window.setFrameTopLeftPoint(NSPoint(x: workspace.frame.maxX, y: workspace.frame.maxY))
        }

        override func mouseUp(with event: NSEvent) {
            workspaceDragOffset = nil
        }
    }
}

struct XiaomiArtwork: View {
    nonisolated static let workspaceHeight: CGFloat = 475

    let highlight: (String) -> Color
    let help: (RemoteKey) -> String
    let activate: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            // The visible portion omits the transparent bottom margin; hotspot coordinates do not.
            let visibleHeightFraction = XiaomiBitmap.visibleHeightFraction
            let height = min(geometry.size.height / visibleHeightFraction, geometry.size.width * XiaomiBitmap.heightToWidth)
            let width = height / XiaomiBitmap.heightToWidth
            ZStack(alignment: .topLeading) {
                if let image = Self.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: width, height: height)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                ForEach(RemoteKey.xiaomi) { key in
                    if let hit = Self.hotspots[key.id] {
                        Button { activate(key.id) } label: {
                            Ellipse()
                                .fill(highlight(key.id))
                                .contentShape(Ellipse())
                                .frame(width: width * hit.width, height: height * hit.height)
                        }
                        .buttonStyle(.plain)
                        .position(x: width * hit.x, y: height * hit.y)
                        .accessibilityLabel(key.name)
                        .help(help(key))
                    }
                }
            }
            .frame(width: width, height: height)
            .frame(height: height * visibleHeightFraction, alignment: .top)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private static let artwork: NSImage? = {
        let packaged = Bundle.main.url(forResource: "RemoteDesk_RemoteDesk", withExtension: "bundle")
            .flatMap(Bundle.init(url:))
        let bundle = packaged ?? .module
        return bundle.url(forResource: "XiaomiRemote2Pro", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }()

    // Normalized against the complete 724 × 2172 image, including its alpha margins.
    private static let hotspots: [String: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
        "power": (0.315, 0.115, 0.166, 0.055), "voice": (0.685, 0.115, 0.166, 0.055),
        "up": (0.50, 0.192, 0.34, 0.049), "down": (0.50, 0.341, 0.34, 0.049),
        "left": (0.274, 0.265, 0.141, 0.112), "right": (0.726, 0.265, 0.141, 0.112),
        "ok": (0.50, 0.267, 0.311, 0.105),
        "back": (0.348, 0.415, 0.235, 0.078), "plus": (0.65, 0.415, 0.235, 0.078),
        "home": (0.348, 0.505, 0.235, 0.078), "minus": (0.65, 0.505, 0.235, 0.078),
        "menu": (0.348, 0.596, 0.235, 0.078), "tv": (0.65, 0.596, 0.235, 0.078)
    ]
}
