import AppKit
import Observation
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class MediaSettings {
    struct Candidate: Identifiable, Codable, Equatable {
        let id: String
        let name: String
        var path: String? = nil
        var webURL: URL? = nil
    }

    struct LaunchItem: Identifiable {
        let candidate: Candidate
        let url: URL
        let icon: NSImage
        var id: String { candidate.id }
    }

    static let builtIn: [Candidate] = [
        .init(id: "com.apple.Music", name: "Apple Music"),
        .init(id: "com.apple.TV", name: "Apple TV"),
        .init(id: "com.spotify.client", name: "Spotify", webURL: URL(string: "https://open.spotify.com/")),
        .init(id: "web.youtube", name: "YouTube", webURL: URL(string: "https://www.youtube.com/")),
        .init(id: "web.netflix", name: "Netflix", webURL: URL(string: "https://www.netflix.com/")),
        .init(id: "web.disneyplus", name: "Disney+", webURL: URL(string: "https://www.disneyplus.com/")),
        .init(id: "com.tencent.QQMusicMac", name: L10n.tr("QQ 音乐")),
        .init(id: "com.youku.mac", name: L10n.tr("优酷")),
        .init(id: "com.iqiyi.player", name: L10n.tr("爱奇艺")),
        .init(id: "com.tencent.tenvideo", name: L10n.tr("腾讯视频")),
        .init(id: "com.netease.163music", name: L10n.tr("网易云音乐")),
        .init(id: "com.bilibili.bilibiliPC", name: L10n.tr("哔哩哔哩")),
        .init(id: "com.colliderli.iina", name: "IINA"),
        .init(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player")
    ]

    private let defaults: UserDefaults
    private(set) var selectedIDs: [String]
    private(set) var custom: [Candidate]
    private var candidateOrder: [String]
    private static let selectionKey = "RemoteDesk.mediaSelection"
    private static let customKey = "RemoteDesk.mediaCustomApps"
    private static let orderKey = "RemoteDesk.mediaCandidateOrder"
    private static let defaultIDs = ["com.tencent.QQMusicMac", "com.youku.mac", "com.iqiyi.player", "com.tencent.tenvideo"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedIDs = defaults.stringArray(forKey: Self.selectionKey) ?? Self.defaultIDs
            .filter { AgentRunner.appURL(AppTarget(bundleID: $0, path: nil)) != nil }
        custom = defaults.data(forKey: Self.customKey)
            .flatMap { try? JSONDecoder().decode([Candidate].self, from: $0) } ?? []
        candidateOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    func resolve(_ candidate: Candidate) -> LaunchItem? {
        let target = AppTarget(bundleID: candidate.id, path: candidate.path)
        if let url = AgentRunner.appURL(target) {
            return LaunchItem(candidate: candidate, url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        guard let url = candidate.webURL else { return nil }
        return LaunchItem(candidate: candidate, url: url, icon: NSWorkspace.shared.icon(for: .url))
    }

    var candidates: [Candidate] {
        let customIDs = Set(custom.map(\.id))
        return Self.builtIn.filter { !customIDs.contains($0.id) } + custom
    }

    var availableCandidates: [Candidate] {
        orderedCandidates.filter { !selectedIDs.contains($0.id) }
    }

    private var orderedCandidates: [Candidate] {
        var remaining = candidates
        let ordered = candidateOrder.compactMap { id -> Candidate? in
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { return nil }
            return remaining.remove(at: index)
        }
        return ordered + remaining
    }

    func placeAvailable(_ id: String, inSlot slot: Int) {
        let order = orderedCandidates.map(\.id)
        guard order.contains(id) else { return }
        var available = availableCandidates.map(\.id)
        var insertion = slot
        if let source = available.firstIndex(of: id) {
            available.remove(at: source)
            if source < insertion { insertion -= 1 }
            if source == insertion { return }
        }
        var updated = order.filter { $0 != id }
        let anchor = available.indices.contains(insertion) ? available[insertion] : nil
        updated.insert(id, at: anchor.flatMap { updated.firstIndex(of: $0) } ?? updated.endIndex)
        candidateOrder = updated
        defaults.set(updated, forKey: Self.orderKey)
        if selectedIDs.contains(id) {
            save(ids: selectedIDs.filter { $0 != id }, custom: custom)
        }
    }

    func selection() -> [LaunchItem] {
        selectedIDs.compactMap { id in
            candidates.first(where: { $0.id == id }).flatMap(resolve)
        }.prefix(MediaGrid.limit).map { $0 }
    }

    func save(ids: [String], custom: [Candidate]) {
        self.custom = custom
        var seen = Set<String>()
        selectedIDs = Array(ids.filter { seen.insert($0).inserted }.prefix(MediaGrid.limit))
        defaults.set(selectedIDs, forKey: Self.selectionKey)
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }

    func place(_ id: String, at index: Int) -> Bool {
        guard candidates.contains(where: { $0.id == id }) else { return false }
        var ids = selectedIDs
        if let existing = ids.firstIndex(of: id) {
            ids.remove(at: existing)
        } else if ids.count >= MediaGrid.limit {
            return false
        }
        ids.insert(id, at: min(max(index, 0), ids.count))
        if ids != selectedIDs { save(ids: ids, custom: custom) }
        return true
    }
}

typealias ShowMediaPreview = ([MediaSettings.LaunchItem], @escaping () -> Void) -> Void

struct MediaSettingsView: View {
    let settings: MediaSettings
    let preview: ShowMediaPreview
    @State private var resolved: [String: MediaSettings.LaunchItem] = [:]
    @State private var error: String?
    @State private var availableFrame = CGRect.zero
    @State private var availableContentTop: CGFloat = 0
    @State private var activeFrame = CGRect.zero
    @State private var activeContentTop: CGFloat = 0
    @GestureState private var drag: AppDrag?
    private let dragSpace = "media-settings"
    @FocusState private var previewFocused: Bool

    private let rowHeight: CGFloat = 34
    private var selected: [String] { settings.selectedIDs }
    private var available: [MediaSettings.Candidate] { settings.availableCandidates }
    private var hasSpace: Bool { selected.count < MediaGrid.limit }

    private struct AppDrag {
        let id: String
        let location: CGPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("可用应用")).font(.headline)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(available.enumerated()), id: \.element.id) { index, candidate in
                                availableRow(candidate, index: index)
                            }
                        }
                        .padding(.horizontal, 8)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(dragSpace)).minY } action: {
                            availableContentTop = $0
                        }
                        .overlay(alignment: .top) {
                            if let drag, let slot = availableSlot(at: drag.location) {
                                insertionLine(at: slot)
                            }
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(dragSpace)) } action: {
                        availableFrame = $0
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.tr("激活的应用")).font(.headline)
                        Spacer()
                        Text(L10n.format("已选 %@ / %@", String(selected.count), String(MediaGrid.limit)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    activeList
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("添加应用…"), action: addApplication)
                Spacer()
                Button(L10n.tr("预览")) {
                    previewFocused = false
                    preview(settings.selection()) { Task { @MainActor in previewFocused = true } }
                }
                .focused($previewFocused)
                .disabled(!selected.contains(where: { resolved[$0] != nil }))
            }
        }
        .coordinateSpace(name: dragSpace)
        .overlay {
            if let drag {
                floatingApp(drag)
            }
        }
        .onAppear(perform: refresh)
    }

    private var activeList: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                        activeRow(id, index: index)
                    }
                    Text(L10n.tr(hasSpace ? "将应用拖到这里" : "拖动应用调整顺序"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(32, geometry.size.height - CGFloat(selected.count) * rowHeight))
                }
                .padding(.horizontal, 8)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(dragSpace)).minY } action: {
                    activeContentTop = $0
                }
                .overlay(alignment: .top) {
                    if let drag, let slot = activeSlot(for: drag.id, at: drag.location) {
                        insertionLine(at: slot)
                    }
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(dragSpace)) } action: {
            activeFrame = $0
        }
    }

    private func insertionLine(at slot: Int) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .offset(y: CGFloat(slot) * rowHeight)
            .allowsHitTesting(false)
    }

    private func availableRow(_ candidate: MediaSettings.Candidate, index: Int) -> some View {
        let item = resolved[candidate.id]
        return HStack(spacing: 6) {
            draggableRowLabel(candidate, id: candidate.id)
                .accessibilityElement(children: .combine)
                .accessibilityActions {
                    if index > 0 {
                        Button(L10n.tr("上移")) { settings.placeAvailable(candidate.id, inSlot: index - 1) }
                    }
                    if index < available.count - 1 {
                        Button(L10n.tr("下移")) { settings.placeAvailable(candidate.id, inSlot: index + 2) }
                    }
                }
            iconButton("plus", title: L10n.tr("激活应用")) {
                _ = settings.place(candidate.id, at: selected.count)
            }
            .disabled(item == nil || !hasSpace)
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }

    private func activeRow(_ id: String, index: Int) -> some View {
        HStack(spacing: 6) {
            draggableRowLabel(settings.candidates.first { $0.id == id }, id: id)
                .accessibilityElement(children: .combine)
                .accessibilityActions {
                    if index > 0 {
                        Button(L10n.tr("上移")) { _ = settings.place(id, at: index - 1) }
                    }
                    if index < selected.count - 1 {
                        Button(L10n.tr("下移")) { _ = settings.place(id, at: index + 1) }
                    }
                }
            iconButton("minus", title: L10n.tr("停用应用")) {
                deactivate(id)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }

    private func draggableRowLabel(_ candidate: MediaSettings.Candidate?, id: String) -> some View {
        appLabel(candidate, id: id)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .opacity(drag?.id == id ? 0.35 : 1)
            .gesture(dragApp(id))
    }

    private func floatingApp(_ drag: AppDrag) -> some View {
        GeometryReader { geometry in
            let width: CGFloat = 190
            appLabel(settings.candidates.first { $0.id == drag.id }, id: drag.id)
                .padding(.horizontal, 10)
                .frame(width: width, height: rowHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary)
                }
                .opacity(0.88)
                .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
                .position(
                    x: min(max(drag.location.x + 12 + width / 2, width / 2), geometry.size.width - width / 2),
                    y: min(max(drag.location.y + rowHeight / 2 + 8, rowHeight / 2), geometry.size.height - rowHeight / 2)
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func appLabel(_ candidate: MediaSettings.Candidate?, id: String) -> some View {
        let item = resolved[id]
        let name = candidate?.name ?? id
        return HStack(spacing: 6) {
            Group {
                if let item, item.url.isFileURL {
                    Image(nsImage: item.icon).resizable().scaledToFit()
                } else {
                    Image(systemName: item == nil ? "app" : "play.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20).accessibilityHidden(true)
            Text(name).lineLimit(1).layoutPriority(1).help(name)
            Spacer(minLength: 0)
            if item == nil || item?.url.isFileURL == false {
                Text(L10n.tr(item == nil ? "未安装" : "网页版"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 15)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(title)
    }

    private func dragApp(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(dragSpace))
            .updating($drag) { value, state, _ in state = AppDrag(id: id, location: value.location) }
            .onEnded { value in
                if let slot = activeSlot(for: id, at: value.location) {
                    placeDroppedApp(id, inSlot: slot)
                } else if let slot = availableSlot(at: value.location) {
                    settings.placeAvailable(id, inSlot: slot)
                }
            }
    }

    private func activeSlot(for id: String, at point: CGPoint) -> Int? {
        guard activeFrame.contains(point) else { return nil }
        guard selected.contains(id) || (hasSpace && resolved[id] != nil) else { return nil }
        return insertionSlot(y: point.y - activeContentTop, count: selected.count)
    }

    private func availableSlot(at point: CGPoint) -> Int? {
        guard availableFrame.contains(point) else { return nil }
        return insertionSlot(y: point.y - availableContentTop, count: available.count)
    }

    private func insertionSlot(y: CGFloat, count: Int) -> Int {
        min(max(Int((y / rowHeight).rounded()), 0), count)
    }

    private func placeDroppedApp(_ id: String, inSlot slot: Int) {
        if let existing = selected.firstIndex(of: id) {
            _ = settings.place(id, at: existing < slot ? slot - 1 : slot)
        } else if resolved[id] != nil {
            _ = settings.place(id, at: slot)
        }
    }

    private func deactivate(_ id: String) {
        settings.save(ids: selected.filter { $0 != id }, custom: settings.custom)
    }

    private func refresh() {
        resolved = Dictionary(uniqueKeysWithValues: settings.candidates.compactMap(settings.resolve).map { ($0.id, $0) })
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = L10n.tr("添加")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            error = L10n.tr("无法识别所选应用。")
            return
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let candidate = MediaSettings.Candidate(id: id, name: name, path: url.path,
                                                webURL: settings.candidates.first { $0.id == id }?.webURL)
        let custom = settings.custom.filter { $0.id != id } + [candidate]
        let activate = !selected.contains(id) && hasSpace && settings.resolve(candidate) != nil
        settings.save(ids: activate ? selected + [id] : selected, custom: custom)
        refresh()
        error = nil
    }
}
