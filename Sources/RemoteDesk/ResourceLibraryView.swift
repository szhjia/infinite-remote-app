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
        let results = entries
        VStack(alignment: .leading, spacing: 16) {
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
            if !library.refreshing.isEmpty { ProgressView(L10n.tr("正在刷新订阅源…")).controlSize(.small) }
            catalogHeading(count: results.count)
            ScrollView {
                if results.isEmpty && library.refreshing.isEmpty {
                    emptyResults.frame(maxWidth: .infinity).padding(40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 360), alignment: .top)], spacing: 16) {
                    ForEach(results.map { LibraryEntry(source: $0.0, listing: $0.1) }) { entry in
                        resourceCard(entry.listing, source: entry.source)
                    }
                }
            }
        }
        .padding(24)
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

    private func catalogHeading(count: Int) -> some View {
        HStack(spacing: 10) {
            Text(L10n.tr("型号目录"))
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(count, format: .number)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel(L10n.format("结果数：%@", count.formatted()))
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
        return VStack(alignment: .leading, spacing: 12) {
            CatalogPreview(url: library.previewURL(listing, source: source))
                .frame(maxWidth: .infinity).frame(height: 140).padding(8)
            if let brand = listing.brand { Text(brand.name.resolve()).font(.caption).foregroundStyle(.secondary) }
            Text(listing.name.resolve()).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(listing.release).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(listing.summary.resolve()).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(source.title).font(.caption).foregroundStyle(.tertiary)
            if let error = library.errors[key] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if library.installing.contains(key) { ProgressView().controlSize(.small) }
                Button(L10n.tr(!own ? "已由其他来源安装" : installed == nil ? "添加遥控器" : update ? "更新" : "已添加")) {
                    Task { await library.install(listing, from: source, into: model) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!own || (installed != nil && !update) || !library.installing.isEmpty || importing || model.hasConfigurationChanges)
                if installed != nil {
                    Button(L10n.tr("选择")) { model.previewModel(listing.id) }
                        .disabled(model.hasConfigurationChanges)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
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
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "appletvremote.gen4").resizable().scaledToFit().foregroundStyle(.tertiary) }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            do {
                let data = try await ResourceLibrary.fetch(url, limit: 4 * 1024 * 1024, session: .shared)
                guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
                      let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
                      let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 280,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return }
                image = NSImage(cgImage: bitmap, size: .zero)
            } catch { /* A missing preview never prevents a validated package install. */ }
        }
    }
}
