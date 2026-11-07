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

    private let accent = Color.accentColor

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
                            VStack(spacing: 4) {
                                Group {
                                    if let url {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                                Text(app.displayName).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                if active {
                                    Label(L10n.tr("生效中"), systemImage: "circle.fill")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(selected ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("添加应用…"))
            .help(L10n.tr("添加应用…"))
            .padding([.horizontal, .bottom], 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
