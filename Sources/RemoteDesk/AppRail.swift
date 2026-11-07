import AppKit
import RemoteCore
import SwiftUI

struct AppRail: View {
    let apps: [AppTarget]
    let selectedBundleID: String
    let activeBundleID: String?
    let chatGPTURL: URL?
    let onSelect: (AppTarget) -> Void
    let onAdd: () -> Void

    @State private var hoveredBundleID: String?
    @State private var isAddHovered = false
    private static let iconSize: CGFloat = 36
    private static let tileSize: CGFloat = 64
    private static let tileShape = RoundedRectangle(cornerRadius: 14)
    private static let tileHighlight = Color.accentColor.opacity(0.13)

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(apps, id: \.bundleID) { app in
                        let selected = app.bundleID == selectedBundleID
                        let isChatGPT = app.bundleID == AppTarget.chatGPT.bundleID
                        let url = isChatGPT ? chatGPTURL : AgentRunner.appURL(app)
                        let active = app.bundleID == activeBundleID && (!isChatGPT || url != nil)
                        Button { onSelect(app) } label: {
                            tile(title: app.displayName, isHighlighted: selected || hoveredBundleID == app.bundleID) {
                                if let url {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                                } else {
                                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if active {
                                    Circle().fill(.blue)
                                        .frame(width: 6, height: 6)
                                        .padding(6)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            if isHovered {
                                hoveredBundleID = app.bundleID
                            } else if hoveredBundleID == app.bundleID {
                                hoveredBundleID = nil
                            }
                        }
                        .accessibilityLabel(app.displayName)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityValue(active ? L10n.tr("生效中") : "")
                        .help(active ? "\(app.displayName) · \(L10n.tr("生效中"))" : app.displayName)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
            }
            Button(action: onAdd) {
                tile(title: L10n.tr("添加应用"), isHighlighted: isAddHovered) {
                    Image(systemName: "plus")
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("添加应用…"))
            .help(L10n.tr("添加应用…"))
            .onHover { isAddHovered = $0 }
            .padding(.bottom, 8)
        }
    }

    private func tile<Icon: View>(title: String, isHighlighted: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 2) {
            icon()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
        .background(isHighlighted ? Self.tileHighlight : .clear, in: Self.tileShape)
        .contentShape(Self.tileShape)
    }
}
