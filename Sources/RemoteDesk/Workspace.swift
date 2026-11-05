import AppKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct Workspace: View {
    let model: RemoteModel
    let mediaSettings: MediaSettings
    let previewMedia: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemPickerSlot: String?
    @State private var hotKeys: [SystemHotKey]?
    @State private var hotKeysError: String?
    @State private var sheet: SettingsSheet?
    @State private var pendingProfile: AgentProfile?
    @State private var profileName = ""
    @State private var approveImportDiscard = false
    @State private var showSystemSettings = false
    @State private var showConfigActions = false
    @State private var previewAfterSheet = false

    private enum SettingsSheet: Identifiable {
        case media, profiles, name, imported(ProfileArchive)
        var id: String {
            switch self {
            case .media: "media"
            case .profiles: "profiles"
            case .name: "name"
            case .imported: "import"
            }
        }
    }

    private let accent = Color.accentColor
    private let mappingFont = Font.system(size: 13)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 192)
            Divider()
            deviceStage.frame(minWidth: 240, idealWidth: 330, maxWidth: .infinity)
            Divider()
            mapping.frame(width: 348)
        }
        .frame(minWidth: 850, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { model.cancelLearning() }
        .sheet(item: $sheet, onDismiss: showRequestedMediaPreview) { sheet in
            switch sheet {
            case .media: MediaSettingsView(settings: mediaSettings) { previewAfterSheet = true }
            case .profiles: profilesSheet
            case .name: nameSheet(archive: nil)
            case let .imported(archive): nameSheet(archive: archive)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HStack(spacing: 0) {
                    Text("ChatGPT/").foregroundStyle(.white)
                    Text("Codex").foregroundStyle(Color(red: 0.78, green: 0.65, blue: 1))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("ChatGPT/Codex")
                .accessibilityAddTraits(.isStaticText)
            } icon: {
                Image(systemName: "bubble.left").foregroundStyle(.white)
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(red: 0.19, green: 0.16, blue: 0.27), in: RoundedRectangle(cornerRadius: 8))
            if AgentRunner.appURL(AgentProfile.chatGPT.target) == nil {
                Label("未找到 ChatGPT 桌面端", systemImage: "exclamationmark.circle")
                    .font(.caption).padding(.horizontal, 10)
            }
            Spacer()
            if model.monitorState == .permission || !model.canPost || !model.canUseAccessibility {
                VStack(alignment: .leading, spacing: 9) {
                    Text("请分别授权应用")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(permissionColor)
                    HStack(spacing: 6) {
                        if model.monitorState == .permission {
                            permission("输入监控", action: model.requestListen)
                        }
                        if !model.canPost || !model.canUseAccessibility {
                            permission("辅助功能", action: model.requestPost)
                        }
                    }
                }
            }
            Divider()
            Button {
                showSystemSettings.toggle()
            } label: {
                Text("系统设置")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSystemSettings, arrowEdge: .top) {
                WorkspacePopoverAction("多媒体设置…") {
                    showSystemSettings = false
                    sheet = .media
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(5)
            }
        }
        .padding(15)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var permissionColor: Color {
        if colorScheme == .dark { Color(red: 1, green: 0.62, blue: 0.26) }
        else { Color(red: 0.73, green: 0.29, blue: 0) }
    }

    private func permission(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).fixedSize()
            }
            .foregroundStyle(permissionColor)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(permissionColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(permissionColor.opacity(0.32))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var deviceStage: some View {
        VStack(spacing: 15) {
            Spacer(minLength: 0)
            XiaomiArtwork(highlight: { key in
                if let press = model.hardwarePress, press.key == key {
                    return press.phase.indicatorColor.opacity(0.55)
                }
                return model.slot == key ? accent.opacity(0.50) : .clear
            }, help: { "\($0.name) · 定位" }, activate: model.selectSlot)
            .frame(maxHeight: XiaomiArtwork.workspaceHeight)
            VStack(spacing: 6) {
                if model.selectableDevices.count > 1 {
                    Picker("遥控器", selection: Binding(
                        get: { model.connectedDevice.flatMap { model.selectableDevices.contains($0) ? $0 : nil } },
                        set: { if let id = $0 { model.selectDevice(id) } }
                    )) {
                        if model.connectedDevice == nil || model.connectedDevice.map(model.ambiguousDevices.contains) == true {
                            Text("选择遥控器").tag(nil as DeviceID?)
                        }
                        ForEach(model.selectableDevices, id: \.self) { id in
                            Text([id.name, id.serial].compactMap { $0 }.joined(separator: " · ")).tag(Optional(id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 225)
                } else {
                    Text("小米蓝牙遥控器 2 Pro").font(.callout.weight(.semibold))
                }
                if !model.ambiguousDevices.isEmpty {
                    Text("无法区分部分同型号遥控器。请在蓝牙设置中断开其中一支。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.connected {
                    Text("按键自动识别")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.connected || !model.ambiguousDevices.isEmpty {
                    Button("打开蓝牙设置") { model.openBluetooth() }.buttonStyle(.link)
                } else if case .failed = model.monitorState {
                    Button("重试监听") { model.refreshPermissions() }.buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxHeight: .infinity)
        .background {
            RadialGradient(colors: [accent.opacity(0.09), .clear], center: .center, startRadius: 12, endRadius: 240)
        }
    }

    private var mapping: some View {
        VStack(spacing: 0) {
            HStack {
                Text("按键配置").font(.callout.weight(.semibold))
                Spacer()
                if let profile = model.profile {
                    Text(profile.id == AgentProfile.defaults.id ? "\(profile.name) · 只读" : profile.name)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(RemoteKey.xiaomi) { key in
                            row(key).id(key.id)
                            if key.id != RemoteKey.xiaomi.last?.id {
                                Divider()
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                }
                .onChange(of: model.slot) { _, slot in
                    if systemPickerSlot != slot { systemPickerSlot = nil }
                    proxy.scrollTo(slot)
                }
            }
            mappingFooter
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ key: RemoteKey) -> some View {
        let selected = model.slot == key.id
        let phase = model.hardwarePress.flatMap { $0.key == key.id ? $0.phase : nil }
        let isPower = key.id == "power"
        return HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 3) {
                Button {
                    model.selectSlot(key.id)
                } label: {
                    Label {
                        Text(key.name).fontWeight(selected ? .semibold : .regular)
                    } icon: {
                        Image(systemName: key.symbol).frame(width: 16)
                    }
                    .font(mappingFont)
                    .foregroundStyle(selected ? accent : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .frame(width: 69, alignment: .leading)
                HStack(spacing: 3) {
                    if let phase {
                        Image(systemName: phase.indicatorSymbol).accessibilityHidden(true)
                        Text(phase.indicatorTitle)
                    }
                }
                .font(.caption2)
                .foregroundStyle(phase?.indicatorColor ?? .secondary)
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
            }
            .frame(minHeight: 24)
            VStack(spacing: 3) {
                mappingControl(key, slot: key.id, prefix: isPower ? "短按" : nil)
                if isPower {
                    mappingControl(key, slot: "power-long", prefix: "长按")
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 32)
        .padding(.horizontal, 9)
        .background(phase?.indicatorColor.opacity(0.13) ?? .clear, in: RoundedRectangle(cornerRadius: 7))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
    }

    private func mappingControl(_ key: RemoteKey, slot: String, prefix: String?) -> some View {
        let action = model.editableActions[slot]
        return Menu {
            Button("不分配动作") { choose(nil, for: key, slot: slot) }
            Section("ChatGPT") {
                actionItem(.openApp, for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.newChat), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.sendDraft), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.stop), for: key, slot: slot)
                if key.id != "power" { actionItem(.dictation, for: key, slot: slot) }
            }
            Section("macOS") {
                ForEach([AgentAction.displaySleep, .lockScreen, .appSwitcher, .showDesktop, .volumeUp, .volumeDown, .appleMenu, .mediaChooser],
                        id: \.title) { option in
                    actionItem(option, for: key, slot: slot)
                }
                Button("选择系统快捷键…") {
                    model.selectSlot(key.id)
                    systemPickerSlot = slot
                    refreshHotKeys()
                }
            }
            Section("键盘按键") {
                ForEach(["up", "down", "left", "right", "ok", "back"], id: \.self) { id in
                    if let action = AgentProfile.defaults.actions[id] {
                        actionItem(action, for: key, slot: slot)
                    }
                }
            }
        } label: {
            Text(action.map(actionLabel) ?? "不分配动作")
                .font(mappingFont)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.regular)
        .frame(minHeight: 24)
        .accessibilityLabel("\(key.name)\(prefix ?? "")的功能")
        .help(action.map { $0 == .displaySleep ? ($0.detail ?? actionLabel($0)) : actionLabel($0) } ?? "不分配动作")
        .overlay(alignment: .leading) {
            if let prefix {
                Text(prefix).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize().offset(x: -27).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func actionItem(_ action: AgentAction, for key: RemoteKey, slot: String) -> some View {
        Button { choose(action, for: key, slot: slot) } label: {
            if action == model.editableActions[slot] {
                Label(actionLabel(action), systemImage: "checkmark")
            } else {
                Text(actionLabel(action))
            }
        }
    }

    private func choose(_ action: AgentAction?, for key: RemoteKey, slot: String) {
        model.selectSlot(key.id)
        model.setAction(action, for: slot)
        systemPickerSlot = nil
    }

    private var mappingFooter: some View {
        let key = RemoteKey.xiaomi.first { $0.id == model.slot } ?? RemoteKey.xiaomi[0]
        let learned = model.editableRemote?.input(for: key.id)
        let action = model.editableActions[key.id]
        let detail = footerDetail(for: key, action: action, learned: learned)
        return VStack(alignment: .leading, spacing: 0) {
            if let slot = systemPickerSlot, slot == key.id || (key.id == "power" && slot == "power-long") {
                systemShortcuts(for: key, slot: slot)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.error != nil || model.storageError != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6)
            }
            Divider()
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    Button(action: model.restoreDefaultActions) {
                        Text("恢复默认").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().frame(height: 12)
                    Button {
                        showConfigActions.toggle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 29)
                            .contentShape(Rectangle())
                            .accessibilityLabel("配置操作")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showConfigActions, arrowEdge: .top) {
                        configurationActions
                    }
                    .padding(.trailing, 3)
                }
                .modifier(FooterGlassSurface())
                footerButton("保存", action: saveProfile)
                    .disabled(!model.hasConfigurationChanges || model.learning != nil)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FooterGlassSurface())
    }

    private var configurationActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            WorkspacePopoverAction("配置列表…") {
                showConfigActions = false
                sheet = .profiles
            }
            WorkspacePopoverAction("导出配置…") {
                showConfigActions = false
                exportProfile()
            }
            WorkspacePopoverAction("导入配置…") {
                showConfigActions = false
                importProfile()
            }
            Divider()
            WorkspacePopoverAction(model.learning == nil ? "手动校准当前键…" : "取消校准") {
                showConfigActions = false
                if model.learning == nil { model.startLearning() }
                else { model.cancelLearning() }
            }
            .disabled(!model.canReadKeys || !model.isEnabled || model.isDiagnosing)
            if model.hasConfigurationChanges {
                WorkspacePopoverAction("撤销未保存的更改") {
                    showConfigActions = false
                    model.discardConfigurationChanges()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(5)
    }

    private func footerDetail(for key: RemoteKey, action: AgentAction?, learned: InputCode?) -> String? {
        if let error = model.storageError ?? model.error { return error }
        if model.learning == key.id { return "请按一下遥控器上的「\(key.name)」。" }
        if model.hasConfigurationChanges { return model.feedback ?? "有未保存的更改。" }
        if action == .dictation, learned?.isKeyboardF5 ?? (key.id == "voice") {
            return "在 ChatGPT 中将「听写快捷键」设为 F5，并解除「点按一次听写」的回车绑定。按住麦克风键说话，松开后转写，按「确定」发送。"
        }
        if let message = model.dictation.phase.message { return message }
        if action == .dictation {
            if !model.canUseAccessibility { return "开启辅助功能后才能使用 Codex 听写。" }
            let button = key.id == "voice" ? "麦克风键" : "「\(key.name)」键"
            return "在 Codex 对话中，按住遥控器的\(button)说话，松开后发送。"
        }
        return model.feedback
    }

    private func systemShortcuts(for key: RemoteKey, slot: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let hotKeys, !hotKeys.isEmpty {
                Menu("选择已启用的快捷键") {
                    ForEach(hotKeys, id: \.self) { shortcut in
                        Button(shortcut.label) { choose(.systemShortcut(shortcut), for: key, slot: slot) }
                    }
                }
            } else {
                Text(hotKeysError ?? "没有可选择的系统快捷键。").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("打开键盘快捷键设置", action: SystemActions.openKeyboardSettings)
                Button("刷新", action: refreshHotKeys)
            }
            .buttonStyle(.link)
        }
    }

    private func refreshHotKeys() {
        do {
            hotKeys = try SystemActions.enabledHotKeys()
            hotKeysError = nil
        } catch {
            hotKeys = nil
            hotKeysError = error.localizedDescription
        }
    }

    private func saveProfile() {
        if model.needsProfileName {
            profileName = ""
            sheet = .name
        } else {
            model.saveConfigurationChanges()
        }
    }

    private func showRequestedMediaPreview() {
        guard previewAfterSheet else { return }
        previewAfterSheet = false
        previewMedia()
    }

    private var profilesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置列表").font(.headline)
            List(model.profiles) { profile in
                let active = model.profile?.id == profile.id
                Button {
                    if model.hasConfigurationChanges { pendingProfile = profile }
                    else { selectProfile(profile) }
                } label: {
                    HStack {
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        if profile.id == AgentProfile.defaults.id {
                            Text("只读").foregroundStyle(.secondary)
                        }
                        if active { Text("当前使用").foregroundStyle(accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(active)
            }
            .listStyle(.bordered)
            if let storageError = model.storageError { Text(storageError).foregroundStyle(.red) }
            Button("关闭") { sheet = nil }.keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .frame(width: 380, height: 300)
        .alert("要切换配置吗？", isPresented: Binding(
            get: { pendingProfile != nil },
            set: { if !$0 { pendingProfile = nil } }
        ), presenting: pendingProfile) { profile in
            Button("取消", role: .cancel) {}
            Button("放弃更改并切换", role: .destructive) { selectProfile(profile, discardingDraft: true) }
        } message: { _ in
            Text("当前有未保存的更改。")
        }
    }

    private func selectProfile(_ profile: AgentProfile, discardingDraft: Bool = false) {
        if model.selectProfile(profile.id, discardingDraft: discardingDraft) { sheet = nil }
    }

    private func nameSheet(archive: ProfileArchive?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(archive == nil ? "保存为自定义配置" : "导入为自定义配置").font(.headline)
            TextField("配置名称", text: $profileName)
            if archive != nil && model.hasConfigurationChanges {
                Toggle("放弃当前未保存的更改", isOn: $approveImportDiscard)
            }
            if let error = model.storageError ?? model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { sheet = nil }.keyboardShortcut(.cancelAction)
                Button("保存配置") {
                    let saved: Bool
                    if let archive {
                        saved = model.importProfile(archive, as: profileName, discardingDraft: approveImportDiscard)
                    } else {
                        saved = model.saveConfigurationChanges(as: profileName)
                    }
                    if saved { sheet = nil }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(archive != nil && model.hasConfigurationChanges && !approveImportDiscard)
            }
        }
        .padding(18)
        .frame(width: 350)
    }

    private func exportProfile() {
        guard let profile = model.profile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name.replacingOccurrences(of: "/", with: "-")).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ProfileArchive(profile).write(to: url) }
        catch { model.reportError("配置导出失败：\(error.localizedDescription)") }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try ProfileArchive.read(from: url)
            profileName = archive.name
            approveImportDiscard = false
            sheet = .imported(archive)
        } catch {
            model.reportError("无法导入该文件。请选择遥控台导出的配置。")
        }
    }

    private func actionLabel(_ action: AgentAction) -> String {
        switch action {
        case let .shortcut(keys): keys.label
        case let .systemShortcut(keys): keys.label
        default: action.title
        }
    }
}

private struct WorkspacePopoverAction: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(hovered ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .frame(minWidth: 86, maxWidth: .infinity, minHeight: 25, alignment: .leading)
                .background(hovered ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

private struct FooterGlassSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let label = content.font(.callout).frame(width: 82, height: 29)
        if #available(macOS 26.0, *) {
            label.glassEffect(isEnabled ? .regular.interactive() : .regular, in: .capsule)
                .opacity(isEnabled ? 1 : 0.55)
        } else {
            label.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary).allowsHitTesting(false))
                .opacity(isEnabled ? 1 : 0.55)
        }
    }
}

struct ConfigurationConnectionStatus: View {
    let model: RemoteModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.canReadKeys ? Color.green : .secondary).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.connectionStatus).font(.callout)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 4)
    }
}

struct ConfigurationResponseSwitch: View {
    @Bindable var model: RemoteModel

    var body: some View {
        if #available(macOS 26.0, *) {
            control
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        } else {
            control.padding(.horizontal, 4)
        }
    }

    private var control: some View {
        HStack(spacing: 7) {
            Text("响应遥控器").font(.callout).accessibilityHidden(true)
            Toggle("响应遥控器", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("响应遥控器")
        }
        .fixedSize()
        .help("暂停时仍可查看按键信号")
    }
}

private extension RemoteModel.HardwarePress.Phase {
    var indicatorTitle: String {
        switch self {
        case .down: "按下"
        case .holding: "长按中"
        case .shortPress: "短按"
        case .longPress: "长按"
        }
    }

    var indicatorSymbol: String {
        switch self {
        case .down: "circle.fill"
        case .holding: "waveform"
        case .shortPress, .longPress: "checkmark.circle.fill"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .down, .shortPress: .green
        case .holding, .longPress: .teal
        }
    }
}
