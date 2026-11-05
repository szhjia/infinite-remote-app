import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct ResourceLibraryView: View {
    let model: RemoteModel
    let library: ResourceLibrary
    var manageSources: (() -> Void)?
    @State private var query = ""
    @State private var selectedSource = ""
    @State private var importError: String?
    @State private var didLoad = false
    @State private var importing = false

    private var entries: [(RemoteSubscription, RemoteListing)] {
        library.sources.filter { selectedSource.isEmpty || $0.id == selectedSource }.flatMap { source in
            (source.catalog?.models ?? []).filter { listing in
                query.isEmpty || [listing.name.resolve(), listing.brand?.name.resolve() ?? "", listing.summary.resolve()]
                    .contains { $0.localizedStandardContains(query) }
            }.map { (source, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("遥控器资源库")).font(.title2.bold())
                    Text(L10n.tr("添加遥控器后，即可在侧栏中选择并配置。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { importPackage() } label: { Label(L10n.tr("导入 ZIP…"), systemImage: "square.and.arrow.down") }
                    .disabled(importing || !library.installing.isEmpty)
                Button { Task { await library.refreshAll() } } label: {
                    Label(L10n.tr("刷新"), systemImage: "arrow.clockwise")
                }.disabled(!library.refreshing.isEmpty)
                if let manageSources { Button(L10n.tr("订阅源…"), action: manageSources) }
            }
            HStack {
                TextField(L10n.tr("搜索遥控器或品牌"), text: $query).textFieldStyle(.roundedBorder)
                Picker(L10n.tr("订阅源"), selection: $selectedSource) {
                    Text(L10n.tr("全部订阅源")).tag("")
                    ForEach(library.sources) { source in Text(source.title).tag(source.id) }
                }.frame(maxWidth: 240)
            }
            if importing { ProgressView(L10n.tr("正在导入资源包…")).controlSize(.small) }
            if let error = importError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = library.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = model.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(model.resourceLoadIssues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(library.sources.filter { library.errors[$0.id] != nil }) { source in
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.callout.bold())
                    Text(library.errors[source.id] ?? "").font(.caption).textSelection(.enabled)
                    if source.catalog != nil { Text(L10n.tr("正在显示上次成功刷新的目录。")) .font(.caption) }
                }.foregroundStyle(.secondary)
            }
            if !library.refreshing.isEmpty { ProgressView(L10n.tr("正在刷新订阅源…")).controlSize(.small) }
            ScrollView {
                if entries.isEmpty && library.refreshing.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(L10n.tr(query.isEmpty ? "暂无可用资源" : "没有匹配的遥控器")).font(.headline)
                        Text(L10n.tr("刷新订阅源，或导入本地 ZIP 资源包。"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 360), alignment: .top)], spacing: 16) {
                    ForEach(entries.map { LibraryEntry(source: $0.0, listing: $0.1) }) { entry in
                        resourceCard(entry.listing, source: entry.source)
                    }
                }
            }
        }
        .padding(24)
        .task {
            guard !didLoad else { return }
            didLoad = true
            for id in library.sources.filter({ $0.catalog == nil }).map(\.id) { await library.refresh(id) }
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

struct SubscriptionSettingsView: View {
    let model: RemoteModel
    let library: ResourceLibrary
    let showSetup: () -> Void
    let showPermission: (PermissionKind) -> Void
    let showMedia: () -> Void
    @State private var newURL = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.tr("设置")).font(.title2.bold())
                GroupBox(L10n.tr("订阅源")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("输入指向 catalog.json 的 HTTPS 地址。移除订阅源不会移除已安装的遥控器。"))
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(library.sources) { source in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(source.title).font(.headline)
                                    Spacer()
                                    Button(L10n.tr("刷新")) { Task { await library.refresh(source.id) } }
                                    Button(L10n.tr("移除"), role: .destructive) {
                                        do { try library.removeSource(source.id); error = nil } catch { self.error = error.localizedDescription }
                                    }
                                }
                                Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let date = source.refreshedAt {
                                    HStack { Text(L10n.tr("上次刷新")); Text(date, style: .date); Text(date, style: .time) }
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let message = library.errors[source.id] { Text(message).font(.caption).foregroundStyle(.red) }
                            }.padding(8).disabled(library.refreshing.contains(source.id) || !library.installing.isEmpty)
                            Divider()
                        }
                        HStack {
                            TextField("https://…/catalog.json", text: $newURL).textFieldStyle(.roundedBorder)
                            Button(L10n.tr("添加订阅源")) {
                                do {
                                    let id = try library.addSource(newURL)
                                    newURL = ""; error = nil
                                    Task { await library.refresh(id) }
                                } catch { self.error = error.localizedDescription }
                            }.disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if let error = library.storageError { Text(error).foregroundStyle(.red) }
                    }.padding(12)
                }
                GroupBox(L10n.tr("权限与引导")) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach([PermissionKind.inputMonitoring, .accessibility]) { kind in
                            HStack {
                                Label(kind.title, systemImage: kind.symbol)
                                Spacer()
                                Text(L10n.tr(kind.granted(in: model) ? "已授权" : "尚未授权")).foregroundStyle(.secondary)
                                Button(L10n.tr("查看")) { showPermission(kind) }
                            }
                        }
                        Divider()
                        Button(L10n.tr("重新打开使用引导"), action: showSetup)
                    }.padding(12)
                }
                GroupBox(L10n.tr("多媒体")) {
                    HStack { Button(L10n.tr("多媒体设置…"), action: showMedia); Spacer() }.padding(12)
                }
                Text(L10n.tr("语言跟随系统设置，支持中文和英语，其他语言使用英语。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

private struct CatalogPreview: View {
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
