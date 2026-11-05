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
    }

    struct Installed: Identifiable {
        let candidate: Candidate
        let url: URL
        let icon: NSImage
        var id: String { candidate.id }
    }

    static let builtIn: [Candidate] = [
        .init(id: "com.tencent.QQMusicMac", name: L10n.tr("QQ 音乐")),
        .init(id: "com.youku.mac", name: L10n.tr("优酷")),
        .init(id: "com.iqiyi.player", name: L10n.tr("爱奇艺")),
        .init(id: "com.tencent.tenvideo", name: L10n.tr("腾讯视频")),
        .init(id: "com.netease.163music", name: L10n.tr("网易云音乐")),
        .init(id: "com.bilibili.bilibiliPC", name: L10n.tr("哔哩哔哩")),
        .init(id: "com.apple.Music", name: L10n.tr("音乐")),
        .init(id: "com.apple.TV", name: "Apple TV"),
        .init(id: "com.colliderli.iina", name: "IINA"),
        .init(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player")
    ]

    private let defaults: UserDefaults
    private(set) var selectedIDs: [String]
    private(set) var custom: [Candidate]
    private static let selectionKey = "RemoteDesk.mediaSelection"
    private static let customKey = "RemoteDesk.mediaCustomApps"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedIDs = defaults.stringArray(forKey: Self.selectionKey) ?? Self.builtIn.prefix(4).map(\.id)
        custom = defaults.data(forKey: Self.customKey)
            .flatMap { try? JSONDecoder().decode([Candidate].self, from: $0) } ?? []
    }

    func installed(_ candidate: Candidate) -> Installed? {
        let target = AppTarget(bundleID: candidate.id, path: candidate.path)
        guard let url = AgentRunner.appURL(target) else { return nil }
        return Installed(candidate: candidate, url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    var candidates: [Candidate] {
        let customIDs = Set(custom.map(\.id))
        return Self.builtIn.filter { !customIDs.contains($0.id) } + custom
    }

    func selection() -> [Installed] {
        selectedIDs.compactMap { id in
            candidates.first(where: { $0.id == id }).flatMap(installed)
        }.prefix(MediaGrid.limit).map { $0 }
    }

    func save(ids: [String], custom: [Candidate]) {
        self.custom = custom
        var seen = Set<String>()
        selectedIDs = Array(ids.filter { seen.insert($0).inserted }.prefix(MediaGrid.limit))
        defaults.set(selectedIDs, forKey: Self.selectionKey)
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }
}

struct MediaSettingsView: View {
    let settings: MediaSettings
    let preview: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var custom: [MediaSettings.Candidate] = []
    @State private var installed: [String: MediaSettings.Installed] = [:]
    @State private var error: String?

    private var candidates: [MediaSettings.Candidate] {
        let customIDs = Set(custom.map(\.id))
        return MediaSettings.builtIn.filter { !customIDs.contains($0.id) } + custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("多媒体设置")).font(.headline)
            List(candidates) { candidate in
                let app = installed[candidate.id]
                Toggle(isOn: selection(for: candidate.id)) {
                    HStack(spacing: 8) {
                        if let app {
                            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "app").frame(width: 24, height: 24)
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        Text(candidate.name)
                        Spacer()
                        if app == nil { Text(L10n.tr("未检测到安装")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(app == nil || (!selected.contains(candidate.id) && selected.count >= MediaGrid.limit))
            }
            .listStyle(.bordered)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("添加应用…"), action: addApplication)
                Text(L10n.format("已选 %@ / %@", String(describing: selected.count), String(describing: MediaGrid.limit))).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) { save(previewing: false) }
                Button(L10n.tr("保存并预览")) { save(previewing: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 470)
        .onAppear {
            selected = settings.selectedIDs
            custom = settings.custom
            refresh()
            selected.removeAll { installed[$0] == nil }
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { enabled in
            if enabled {
                if selected.count < MediaGrid.limit, !selected.contains(id) { selected.append(id) }
            } else {
                selected.removeAll { $0 == id }
            }
        })
    }

    private func refresh() {
        installed = Dictionary(uniqueKeysWithValues: candidates.compactMap(settings.installed).map { ($0.id, $0) })
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
        custom.removeAll { $0.id == id }
        custom.append(.init(id: id, name: name, path: url.path))
        refresh()
        if installed[id] != nil, selected.count < MediaGrid.limit, !selected.contains(id) { selected.append(id) }
        error = nil
    }

    private func save(previewing: Bool) {
        settings.save(ids: selected, custom: custom)
        if previewing { preview() }
        dismiss()
    }
}
