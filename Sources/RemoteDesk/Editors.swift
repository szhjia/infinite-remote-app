import AppKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditor: View {
    @State var profile: AgentProfile
    let isNew: Bool
    let canRemove: Bool
    let save: (AgentProfile) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showRemove = false
    @State private var chooseApp = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新建 Agent 方案" : "编辑 Agent 方案").font(.title2.bold())
            TextField("方案名称", text: $profile.name)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 7) {
                Text("目标应用").font(.headline)
                if let url = AgentRunner.appURL(profile.target) {
                    Text(FileManager.default.displayName(atPath: url.path)).font(.callout)
                } else {
                    Text(profile.target.map { "\($0.bundleID)（未找到）" } ?? "未选择")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("选择应用…") { chooseApp = true }
                Text("打开应用和快捷键动作使用此目标。若使用 Claude Code，请在所选终端里先启动会话。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                if !isNew && canRemove {
                    Button("删除方案", role: .destructive) { showRemove = true }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(23)
        .frame(width: 430)
        .fileImporter(isPresented: $chooseApp, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case let .success(url):
                guard let id = Bundle(url: url)?.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier else { error = "请选择另一个有效的 macOS 应用。"; return }
                profile.target = .init(bundleID: id, path: url.path)
                error = nil
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("删除「\(profile.name)」及其动作？", isPresented: $showRemove, titleVisibility: .visible) {
            Button("删除方案", role: .destructive) { remove(); dismiss() }
        }
    }
}

struct ActionEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case none = "无动作"
        case app = "打开目标应用"
        case link = "打开网页"
        case shortcut = "发送应用快捷键"
        case chatBar = "打开 ChatGPT Chat Bar"
        case next = "切换到下一个 Agent"
        var id: Self { self }
    }

    let key: RemoteKey
    let target: AppTarget?
    let save: (AgentAction?) -> Void
    @State private var kind: Kind
    @State private var address = ""
    @State private var shortcut: RemoteCore.KeyboardShortcut?
    @State private var capturing = false
    @State private var monitor: Any?
    @Environment(\.dismiss) private var dismiss

    init(key: RemoteKey, action: AgentAction?, target: AppTarget?, save: @escaping (AgentAction?) -> Void) {
        self.key = key
        self.target = target
        self.save = save
        switch action {
        case nil: _kind = State(initialValue: .none)
        case .openApp: _kind = State(initialValue: .app)
        case let .openLink(url): _kind = State(initialValue: .link); _address = State(initialValue: url)
        case let .shortcut(keys): _kind = State(initialValue: .shortcut); _shortcut = State(initialValue: keys)
        case .chatBar: _kind = State(initialValue: .chatBar)
        case .nextAgent: _kind = State(initialValue: .next)
        }
    }

    private var action: AgentAction? {
        switch kind {
        case .none: nil
        case .app: .openApp
        case .link: AgentRunner.webURL(address).map { .openLink($0.absoluteString) }
        case .shortcut: shortcut.map(AgentAction.shortcut)
        case .chatBar: .chatBar
        case .next: .nextAgent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配置「\(key.name)」").font(.title2.bold())
            Picker("触发动作", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch kind {
            case .link:
                TextField("网页地址（https://…）", text: $address)
            case .shortcut:
                HStack {
                    Text(shortcut?.label ?? "尚未录入").font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(capturing ? "取消录入" : "录入快捷键") {
                        if capturing { stopCapture() } else { capture() }
                    }
                }
                Text(capturing ? "请按下要录入的组合键或单键，例如 Esc。" : "快捷键会发送到当前方案指定的应用。")
                    .font(.caption).foregroundStyle(.secondary)
            case .chatBar:
                Text("向系统发送 ⌥Space。需要已运行且保留默认快捷键的 ChatGPT Chat Bar。")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            if (kind == .app || kind == .shortcut) && AgentRunner.appURL(target) == nil {
                Text("目标应用不可用。保存后可到「编辑当前方案」选择应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") { save(action); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(capturing || (kind != .none && action == nil))
            }
        }
        .padding(23)
        .frame(width: 440)
        .onChange(of: kind) { stopCapture() }
        .onDisappear { stopCapture() }
    }

    private func capture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let repeats = event.isARepeat
            let flags = event.modifierFlags
            let characters = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
            MainActor.assumeIsolated {
                guard !repeats else { return }
                var modifiers: Set<RemoteCore.KeyboardShortcut.Modifier> = []
                if flags.contains(.command) { modifiers.insert(.command) }
                if flags.contains(.control) { modifiers.insert(.control) }
                if flags.contains(.option) { modifiers.insert(.option) }
                if flags.contains(.shift) { modifiers.insert(.shift) }
                let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
                    76: "Enter", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
                let printable = characters.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                        && !(0xF700...0xF8FF).contains($0.value)
                }
                let label = names[keyCode] ?? (!characters.isEmpty && printable ? characters : "Key \(keyCode)")
                shortcut = .init(keyCode: keyCode, modifiers: modifiers, keyName: label)
                stopCapture()
            }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }
}
