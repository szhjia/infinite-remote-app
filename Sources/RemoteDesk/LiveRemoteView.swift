import AppKit
import RemoteCore
import SwiftUI

struct LiveRemoteView: View {
    nonisolated static let preferredHeight: CGFloat = 451

    let model: RemoteModel
    let workspaceVisible: () -> Bool
    let toggleWorkspace: () -> Void
    @Binding var isAlwaysOnTop: Bool
    let hideModel: () -> Void
    let confirmQuit: () -> Void

    @State private var hovering = false
    @State private var pointerKey: String?
    @State private var release: RemoteKeyRelease?

    var body: some View {
        DockedRemoteLayout(ratio: model.remoteDefinition.layout.bodyRatio) {
            casing
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var casing: some View {
        RemoteArtwork(definition: model.remoteDefinition,
                      highlight: { _ in .clear },
                      help: help(for:), activate: { key in
                          pointerKey = nil
                          model.pressVirtualKey(key)
                      },
                      onKeyPressChanged: { key, pressed in
                          if pressed { pointerKey = key }
                          else if pointerKey == key { pointerKey = nil }
                      })
            .disabled(!model.connected)
            .background(RemoteDragSurface())
            .overlay {
                RemoteKeyFeedback(layout: model.remoteDefinition.layout,
                                  pressedKey: pointerKey ?? model.pressedHardwareKey, release: release)
            }
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
        .onChange(of: model.lastKeyRelease) { _, event in release = event }
        .onChange(of: model.remoteDefinition.id) { _, _ in clearFeedback() }
        .onChange(of: model.connected) { _, connected in if !connected { clearFeedback() } }
        .onDisappear {
            hovering = false
            clearFeedback()
        }
    }

    private func clearFeedback() {
        pointerKey = nil
        release = nil
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

private struct RemoteKeyFeedback: View {
    let layout: RemoteDefinition.Layout
    let pressedKey: String?
    let release: RemoteKeyRelease?

    var body: some View {
        GeometryReader { geometry in
            let projection = ArtworkProjection(layout: layout, available: geometry.size)
            let diameter = min(26, max(14, projection.size.width * 0.17))
            ZStack(alignment: .topLeading) {
                if let release, let key = layout.keys.first(where: { $0.id == release.key }) {
                    ReleaseRipple(diameter: diameter)
                        .id(release.id)
                        .position(projection.center(for: key.shape))
                }
                if let pressedKey, let key = layout.keys.first(where: { $0.id == pressedKey }) {
                    PressedGlass()
                        .frame(width: diameter, height: diameter)
                        .position(projection.center(for: key.shape))
                        .transition(.identity)
                }
            }
            .frame(width: projection.size.width, height: projection.size.height, alignment: .topLeading)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PressedGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let tint = Color(red: 0.47, green: 0.76, blue: 1)

    var body: some View {
        surface.overlay {
            Circle().strokeBorder(.linearGradient(
                colors: [.white.opacity(0.92), tint.opacity(0.35), tint.opacity(0.8)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: 1)
        }
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            Circle().fill(Color(red: 0.20, green: 0.39, blue: 0.56))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                Circle().fill(.white.opacity(0.08))
                    .glassEffect(.clear.tint(tint.opacity(0.28)), in: Circle())
            } else {
                frostedSurface
            }
            #else
            frostedSurface
            #endif
        }
    }

    private var frostedSurface: some View {
        Circle().fill(.thinMaterial)
            .overlay {
                Circle().fill(.radialGradient(
                    colors: [.white.opacity(0.38), tint.opacity(0.18), tint.opacity(0.04)],
                    center: .topLeading, startRadius: 0, endRadius: 24
                ))
            }
    }
}

private struct ReleaseRipple: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            ring(lineWidth: 1.25)
                .scaleEffect(expanded && !reduceMotion ? 2.15 : 1)
                .opacity(expanded ? 0 : 0.85)
                .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.34), value: expanded)
            if !reduceMotion {
                ring(lineWidth: 0.85)
                    .scaleEffect(expanded ? 1.72 : 0.8)
                    .opacity(expanded ? 0 : 0.48)
                    .animation(.easeOut(duration: 0.32).delay(0.04), value: expanded)
            }
        }
        .onAppear { expanded = true }
    }

    private func ring(lineWidth: CGFloat) -> some View {
        Circle().strokeBorder(.linearGradient(
            colors: [.white, Color(red: 0.48, green: 0.78, blue: 1).opacity(0.8)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ), lineWidth: lineWidth)
        .frame(width: diameter, height: diameter)
    }
}

private struct DockedRemoteLayout: Layout {
    let ratio: CGFloat
    private let gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = min(LiveRemoteView.preferredHeight, bounds.height, max(0, bounds.width - gap) / ratio)
        subviews[0].place(at: CGPoint(x: bounds.minX + gap, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: height * ratio, height: height))
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
