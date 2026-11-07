import SwiftUI

struct WorkspaceSidebar: View {
    enum SidebarItem: Hashable { case setup, remote(String), library }

    let remotes: [RemoteDefinition]
    let hasRemote: Bool
    let selectedModelID: String
    let blocksModelSwitch: Bool
    let selection: SidebarItem
    let focus: FocusState<SidebarItem?>.Binding
    let onNavigate: (Workspace.Page) -> Void
    let onSelectRemote: (String) -> Void
    let onShowSettings: () -> Void

    private let accent = Color.accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    WorkspaceBrand()
                        .padding(.horizontal, 10)
                        .accessibilityAddTraits(.isHeader)
                    if !hasRemote {
                        sidebarLink(L10n.tr("添加遥控器"), symbol: "appletvremote.gen4", destination: .remote)
                    }
                    ForEach(remotes, id: \.id) { definition in
                        let item = SidebarItem.remote(definition.id)
                        let selected = selection == item
                        Button {
                            onSelectRemote(definition.id)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                if let logo = definition.logo {
                                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                } else {
                                    Image(systemName: "appletvremote.gen4").frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                }
                                Text(definition.manifest.name).font(.callout.weight(.medium))
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selected
                                ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(blocksModelSwitch && selectedModelID != definition.id)
                        .focused(focus, equals: item)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .help(definition.manifest.name)
                    }
                }
            }
            VStack(spacing: 6) {
                sidebarLink(Workspace.Page.library.title, symbol: "square.grid.2x2", destination: .library)
                Button(action: onShowSettings) {
                    Label(L10n.tr("应用设置"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), ignoresSafeAreaEdges: .top)
    }

    private func sidebarLink(_ title: String, symbol: String, destination: Workspace.Page) -> some View {
        let item: SidebarItem = destination == .library ? .library : .setup
        let selected = selection == item
        return Button { onNavigate(destination) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(selected ? accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focus, equals: item)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceBrand: View {
    var body: some View {
        Label {
            Text(L10n.tr("无限遥控器")).font(.system(size: 13, weight: .semibold))
        } icon: {
            Image("BridgeBrand", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}
