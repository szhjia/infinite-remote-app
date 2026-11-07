import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct ResourceLibraryView: View {
    let model: RemoteModel
    let library: ResourceLibrary
    let openWorkspace: (String) -> Void
    @State private var query = ""
    @State private var selectedSource = ""
    @State private var importError: String?
    @State private var didLoad = false
    @State private var importing = false
    @State private var recentlyInstalledID: String?
    @FocusState private var searchFocused: Bool

    private var installedVersions: [String: String] {
        Dictionary(uniqueKeysWithValues: model.installedModels.map { ($0.id, $0.manifest.release) })
    }

    private var entries: [(RemoteSubscription, RemoteListing)] {
        library.sources.filter { selectedSource.isEmpty || $0.id == selectedSource }.flatMap { source in
            (source.catalog?.models ?? []).filter { listing in
                query.isEmpty || [listing.name.resolve(), listing.brand?.name.resolve() ?? "", listing.summary.resolve()]
                    .contains { $0.localizedStandardContains(query) }
            }.map { (source, $0) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            catalog(width: geometry.size.width)
        }
        .onChange(of: installedVersions) { previous, current in
            if let id = current.keys.sorted().first(where: { current[$0] != previous[$0] }) {
                recentlyInstalledID = id
            }
        }
        .onChange(of: library.sources.map(\.id)) { _, sourceIDs in
            if sourceIDs.count < 2 || !sourceIDs.contains(selectedSource) { selectedSource = "" }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            for id in library.sources.filter({ $0.catalog == nil }).map(\.id) { await library.refresh(id) }
        }
    }

    private func catalog(width: CGFloat) -> some View {
        let results = entries
        let minimumGutter: CGFloat = 16
        let columns = max(1, Int((width - minimumGutter) / (ResourceCard.width + minimumGutter)))
        let gutter = max(0, (width - CGFloat(columns) * ResourceCard.width) / CGFloat(columns + 1))
        let gridWidth = CGFloat(columns) * ResourceCard.width + CGFloat(columns - 1) * gutter

        return VStack(alignment: .leading, spacing: 16) {
            libraryActions
            if let id = recentlyInstalledID,
               let definition = model.installedModels.first(where: { $0.id == id }) {
                HStack {
                    Label(L10n.format("已添加型号：%@", definition.manifest.name), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.tr("打开工作台")) { openWorkspace(id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.hasConfigurationChanges && model.remoteDefinition.id != id)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if importing { ProgressView(L10n.tr("正在导入资源包…")).controlSize(.small) }
            if let error = importError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = library.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = model.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(model.resourceLoadIssues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            sourceIssues
            ScrollView {
                if results.isEmpty && library.refreshing.isEmpty {
                    emptyResults.frame(maxWidth: .infinity).padding(40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(ResourceCard.width), spacing: gutter),
                                         count: columns), alignment: .leading, spacing: 16) {
                    ForEach(results.map { LibraryEntry(source: $0.0, listing: $0.1) }) { entry in
                        resourceCard(entry.listing, source: entry.source)
                    }
                }
                .frame(width: gridWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, gutter)
        .padding(.vertical, 24)
    }

    private var libraryActions: some View {
        HStack(spacing: 10) {
            searchField.frame(maxWidth: 270)
            Button { importPackage() } label: {
                Label(L10n.tr("导入 ZIP"), systemImage: "square.and.arrow.down")
            }
            .disabled(importing || !library.installing.isEmpty)
            Button {
                Task { await library.refreshAll() }
            } label: {
                Label(L10n.tr("刷新订阅源"), systemImage: "arrow.clockwise")
            }
            .disabled(library.sources.isEmpty || !library.refreshing.isEmpty)
            ZStack {
                Color.clear.accessibilityHidden(true)
                if !library.refreshing.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.tr("正在刷新订阅源…"))
                }
            }
            .frame(width: 16, height: 16)
            if library.sources.count > 1 {
                Picker(L10n.tr("筛选订阅源"), selection: $selectedSource) {
                    Text(L10n.tr("全部订阅源")).tag("")
                    ForEach(library.sources) { source in Text(source.title).tag(source.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.tr("搜索遥控器或品牌"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("清除搜索"))
                .help(L10n.tr("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: searchFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var sourceIssues: some View {
        let failedSources = library.sources.filter { library.errors[$0.id] != nil }
        if !failedSources.isEmpty {
            DisclosureGroup(L10n.format("%@ 个订阅源刷新失败", failedSources.count.formatted())) {
                ForEach(failedSources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.title).font(.callout.bold())
                        Text(library.errors[source.id] ?? "").font(.caption).textSelection(.enabled)
                        if source.catalog != nil {
                            Text(L10n.tr("正在显示上次成功刷新的目录。")).font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if !query.isEmpty {
                Text(L10n.tr("没有匹配的遥控器")).font(.headline)
                Button(L10n.tr("清除搜索")) { query = "" }
            } else if !selectedSource.isEmpty {
                Text(L10n.tr("此订阅源暂无可用资源")).font(.headline)
                Button(L10n.tr("查看全部订阅源")) { selectedSource = "" }
            } else if library.sources.isEmpty {
                Text(L10n.tr("尚未添加订阅源")).font(.headline)
                Text(L10n.tr("在「应用设置」的「订阅源」中添加。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if library.sources.allSatisfy({ $0.catalog == nil }) {
                Text(L10n.tr("未能载入资源目录")).font(.headline)
                Button(L10n.tr("刷新")) { Task { await library.refreshAll() } }
            } else {
                Text(L10n.tr("暂无可用资源")).font(.headline)
                Text(L10n.tr("刷新订阅源，或导入本地 ZIP 资源包。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func resourceCard(_ listing: RemoteListing, source: RemoteSubscription) -> some View {
        let installed = model.installedModels.first { $0.id == listing.id }
        let key = source.id + ":" + listing.id
        let own = installed == nil || model.installedOwner(of: listing.id) == source.id
        let update = installed.map { listing.release.compare($0.manifest.release, options: .numeric) == .orderedDescending } ?? false
        let localArtwork = own ? installed?.artwork : nil
        let localLogo = own && installed?.manifest.brand?.id == listing.brand?.id ? installed?.logo : nil
        return ResourceCard(
            listing: listing, sourceTitle: source.title,
            previewURL: library.previewURL(listing, source: source), localArtwork: localArtwork,
            brandLogoURL: library.brandLogoURL(listing, source: source), localLogo: localLogo,
            isInstalled: installed != nil, ownsInstallation: own, hasUpdate: update,
            isInstalling: library.installing.contains(key),
            canInstall: library.installing.isEmpty && !importing && !model.hasConfigurationChanges,
            canOpen: !model.hasConfigurationChanges || model.remoteDefinition.id == listing.id,
            error: library.errors[key]
        ) {
            Task { await library.install(listing, from: source, into: model) }
        } open: {
            openWorkspace(listing.id)
        }
    }

    private func importPackage() {
        guard !model.hasConfigurationChanges else { importError = L10n.tr("请先保存或放弃当前配置更改。"); return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("导入遥控器资源包")
        panel.message = L10n.tr("选择 ZIP 资源包或已解压的型号文件夹。")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do { try await model.installResourcePackage(from: url); importError = nil }
            catch { importError = error.localizedDescription }
        }
    }
}

private struct ResourceCard: View {
    static let width: CGFloat = 344
    private static let previewHeight: CGFloat = 96
    private static let titleSize: CGFloat = 16
    private static let titleLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    let listing: RemoteListing
    let sourceTitle: String
    let previewURL: URL?
    let localArtwork: NSImage?
    let brandLogoURL: URL?
    let localLogo: NSImage?
    let isInstalled: Bool
    let ownsInstallation: Bool
    let hasUpdate: Bool
    let isInstalling: Bool
    let canInstall: Bool
    let canOpen: Bool
    let error: String?
    let install: () -> Void
    let open: () -> Void

    @State private var showsError = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CatalogPreview(url: previewURL, fallback: localArtwork)
                    .frame(width: 52, height: Self.previewHeight, alignment: .top)
                VStack(alignment: .leading, spacing: 6) {
                    titleRow
                    Text(listing.summary.resolve())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(listing.summary.resolve())
                    Text(sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(sourceTitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.previewHeight, alignment: .top)
            .padding(.horizontal, 16)
            .frame(height: 116)
            footer
        }
        .frame(width: Self.width, height: 160)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(listing.name.resolve())
                    .font(.system(size: Self.titleSize, weight: .semibold))
                    .lineLimit(1)
                    .help(listing.name.resolve())
                if let brand = listing.brand {
                    CatalogBrandMark(url: brandLogoURL, fallback: localLogo, name: brand.name.resolve(),
                                     height: Self.titleLineHeight)
                }
            }
            Spacer(minLength: 0)
            Text(listing.release)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 68, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                .help(listing.release)
        }
        .frame(height: Self.titleLineHeight)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isInstalling {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.tr("正在添加遥控器…"))
            } else if isInstalled {
                Label {
                    Text(L10n.tr(ownsInstallation ? "已添加" : "已由其他来源安装"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            }
            if let error {
                Button { showsError.toggle() } label: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(error)
                .help(error)
                .popover(isPresented: $showsError) {
                    Text(error).textSelection(.enabled).padding(14).frame(width: 280)
                }
            }
            Spacer(minLength: 4)
            if ownsInstallation && (!isInstalled || hasUpdate) {
                Button(L10n.tr(hasUpdate ? "更新" : "添加遥控器"), action: install)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)
            }
            if isInstalled {
                Button(action: open) {
                    HStack(spacing: 7) {
                        Text(L10n.tr("打开工作台"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canOpen)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045))
    }
}

private struct LibraryEntry: Identifiable {
    let source: RemoteSubscription
    let listing: RemoteListing
    var id: String { source.id + ":" + listing.id }
}

enum AppSettingsPane: String, CaseIterable, Identifiable {
    case permissions, sources, media
    var id: Self { self }
    var title: String {
        switch self {
        case .permissions: L10n.tr("权限与引导")
        case .sources: L10n.tr("订阅源")
        case .media: L10n.tr("多媒体")
        }
    }
}

struct AppSettingsView: View {
    let model: RemoteModel
    let library: ResourceLibrary
    let mediaSettings: MediaSettings
    @Binding var pane: AppSettingsPane
    let showSetup: () -> Void
    let previewMedia: ShowMediaPreview
    @Environment(\.dismiss) private var dismiss
    @State private var permission: PermissionKind?

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.tr("设置"), selection: $pane) {
                ForEach(AppSettingsPane.allCases) { pane in Text(pane.title).tag(pane) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .padding(14)
            Divider()
            switch pane {
            case .sources:
                SubscriptionSourcesView(library: library)
                    .padding(18)
            case .media:
                MediaSettingsView(settings: mediaSettings, preview: previewMedia)
                    .padding(18)
            case .permissions:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        permissionsPane
                        Text(L10n.tr("语言跟随系统设置，支持中文和英语，其他语言使用英语。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $permission) { kind in
            PermissionStepView(kind: kind, model: model) { permission = nil }.frame(width: 430)
        }
    }

    private var permissionsPane: some View {
        GroupBox(L10n.tr("权限与引导")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([PermissionKind.inputMonitoring, .accessibility]) { kind in
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        Text(kind.status(in: model).title).foregroundStyle(.secondary)
                        Button(L10n.tr("查看")) { permission = kind }
                    }
                }
                Divider()
                Button(L10n.tr("重新打开使用引导")) {
                    dismiss()
                    showSetup()
                }
            }.padding(12)
        }
    }
}

private struct SubscriptionSourcesView: View {
    let library: ResourceLibrary
    @State private var selection: RemoteSubscription.ID?
    @State private var editor: SourceEditorRequest?
    @State private var actionError: String?

    private var selected: RemoteSubscription? { library.sources.first { $0.id == selection } }
    private var canRefresh: Bool {
        guard let selected else { return false }
        return !library.refreshing.contains(selected.id)
    }
    private var canRemove: Bool {
        guard let selected else { return false }
        return !selected.isDefault && canRefresh && library.installing.isEmpty && library.storageError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(library.sources, selection: $selection) {
                TableColumn(L10n.tr("名称")) { source in
                    HStack(spacing: 6) {
                        Text(source.title).lineLimit(1).help(source.title)
                        if source.isDefault {
                            Text(L10n.tr("默认")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
                .width(min: 180, ideal: 210)
                TableColumn(L10n.tr("目录地址")) { source in
                    HStack {
                        Text(source.url.absoluteString)
                            .lineLimit(1).truncationMode(.middle)
                            .help(source.url.absoluteString)
                        Spacer(minLength: 0)
                        if library.refreshing.contains(source.id) {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(L10n.tr("正在刷新订阅源…"))
                        } else if let message = library.errors[source.id] {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.red).help(message).accessibilityLabel(message)
                        }
                    }
                }
                .width(min: 210)
            }
            .accessibilityLabel(L10n.tr("订阅源"))
            HStack {
                Button(L10n.tr("添加订阅源")) { openEditor() }
                    .disabled(library.storageError != nil)
                Button(L10n.tr("编辑…")) { if let selected { openEditor(selected) } }
                    .disabled(selected == nil || library.storageError != nil)
                Button(L10n.tr("移除"), role: .destructive, action: removeSelected)
                    .disabled(!canRemove)
                Spacer()
                Button(L10n.tr("刷新")) {
                    if let selection { Task { await library.refresh(selection) } }
                }
                .disabled(!canRefresh)
            }
            if let message = actionError ?? library.storageError ?? selection.flatMap({ library.errors[$0] }) {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { selection = library.sources.first?.id }
        .onChange(of: selection) { actionError = nil }
        .sheet(item: $editor) { request in
            SubscriptionSourceEditor(source: request.source) { address, name in
                try saveSource(request.source, address: address, name: name)
            }
        }
    }

    private func openEditor(_ source: RemoteSubscription? = nil) {
        editor = SourceEditorRequest(source: source)
    }

    private func saveSource(_ source: RemoteSubscription?, address: String, name: String) throws {
        let id = try source.map { try library.updateSource($0.id, url: address, name: name) }
            ?? library.addSource(address, name: name)
        actionError = nil
        selection = id
        editor = nil
        if id != source?.id { Task { await library.refresh(id) } }
    }

    private func removeSelected() {
        guard let selection else { return }
        do {
            try library.removeSource(selection)
            self.selection = library.sources.first?.id
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct SourceEditorRequest: Identifiable {
    let id = UUID()
    let source: RemoteSubscription?
}

private struct SubscriptionSourceEditor: View {
    let source: RemoteSubscription?
    let save: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var error: String?

    init(source: RemoteSubscription?, save: @escaping (String, String) throws -> Void) {
        self.source = source
        self.save = save
        _name = State(initialValue: source?.customName ?? "")
        _address = State(initialValue: source?.url.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(source == nil ? "添加订阅源" : "编辑订阅源")).font(.headline)
            Form {
                TextField(L10n.tr("名称"), text: $name, prompt: Text(L10n.tr("自动名称")))
                TextField(L10n.tr("目录地址"), text: $address, prompt: Text("https://…/catalog.json"))
                    .disabled(source?.isDefault == true)
            }
            .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) {
                    do { try save(address, name) } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }
}

struct CatalogPreview: View {
    let url: URL?
    var fallback: NSImage? = nil
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? fallback { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "appletvremote.gen4").resizable().scaledToFit().foregroundStyle(.tertiary) }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            let loaded = await CatalogImage.load(url, maxPixelSize: 280)
            if !Task.isCancelled { image = loaded }
        }
    }
}

private struct CatalogBrandMark: View {
    let url: URL?
    let fallback: NSImage?
    let name: String
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? fallback {
                let aspect = image.size.width / max(image.size.height, 1)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(56, height * aspect), height: height)
                    .fixedSize()
                    .accessibilityLabel(name)
                    .help(name)
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await CatalogImage.load(url, maxPixelSize: 112)
            if !Task.isCancelled { image = loaded }
        }
    }
}

private enum CatalogImage {
    @MainActor static func load(_ url: URL?, maxPixelSize: Int) async -> NSImage? {
        guard let url,
              let data = try? await ResourceLibrary.fetch(url, limit: 4 * 1024 * 1024, session: .shared),
              !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap, size: .zero)
    }
}
