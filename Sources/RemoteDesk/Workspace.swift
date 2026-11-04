import AppKit
import RemoteCore
import SwiftUI

struct Workspace: View {
    let model: RemoteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemPickerSlot: String?
    @State private var hotKeys: [SystemHotKey]?
    @State private var hotKeysError: String?

    private let accent = Color.accentColor

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 192)
            Divider()
            deviceStage.frame(minWidth: 240, idealWidth: 330, maxWidth: .infinity)
            Divider()
            mapping.frame(minWidth: 390, idealWidth: 455, maxWidth: 515)
        }
        .frame(minWidth: 850, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { model.cancelLearning() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ChatGPT", systemImage: "bubble.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text("桌面端 Codex")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            if AgentRunner.appURL(AgentProfile.chatGPT.target) == nil {
                Label("未找到 ChatGPT 桌面端", systemImage: "exclamationmark.circle")
                    .font(.caption).padding(.horizontal, 10)
            }
            Spacer()
            if model.monitorState == .permission {
                permission("开启输入监控后，遥控台才能读取按键。", button: "打开输入监控设置", action: model.requestListen)
            }
            if !model.canPost || !model.canUseAccessibility {
                permission("ChatGPT 和菜单动作需要辅助功能权限。", button: "打开辅助功能设置", action: model.requestPost)
            }
        }
        .padding(15)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func permission(_ explanation: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(button, action: action).buttonStyle(.link)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
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
            .frame(maxHeight: 475)
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
                    Text("\(model.learnedCount) / 13 已录入")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(RemoteKey.xiaomi) { key in
                            row(key).id(key.id)
                            if key.id != RemoteKey.xiaomi.last?.id {
                                Divider().padding(.horizontal, 9)
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
            Divider()
            mappingFooter
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ key: RemoteKey) -> some View {
        let action = model.editableActions[key.id]
        let selected = model.slot == key.id
        let phase = model.hardwarePress.flatMap { $0.key == key.id ? $0.phase : nil }
        return HStack(spacing: 10) {
            Button {
                model.selectSlot(key.id)
            } label: {
                Label {
                    Text(key.name)
                        .fontWeight(selected ? .semibold : .regular)
                } icon: {
                    Image(systemName: key.symbol).frame(width: 20)
                }
                .foregroundStyle(selected ? accent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if let phase {
                Label {
                    Text(phase.indicatorTitle)
                } icon: {
                    Image(systemName: phase.indicatorSymbol).foregroundStyle(phase.indicatorColor)
                }
                .font(.caption)
                .lineLimit(1)
                .transition(.opacity)
            }
            actionMenu(key, action: action)
                .frame(width: 174)
        }
        .frame(minHeight: 37)
        .padding(.horizontal, 9)
        .background(phase?.indicatorColor.opacity(0.13) ?? .clear, in: RoundedRectangle(cornerRadius: 7))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
    }

    private func actionMenu(_ key: RemoteKey, action: AgentAction?) -> some View {
        Menu {
            Button("不分配动作") { choose(nil, for: key) }
            Section("ChatGPT") {
                actionItem(.openApp, for: key)
                actionItem(.shortcut(AgentProfile.newChat), for: key)
                actionItem(.shortcut(AgentProfile.sendDraft), for: key)
                actionItem(.shortcut(AgentProfile.stop), for: key)
                actionItem(.dictation, for: key)
            }
            Section("macOS") {
                actionItem(.displaySleep, for: key)
                actionItem(.appleMenu, for: key)
                Button("选择系统快捷键…") {
                    model.selectSlot(key.id)
                    systemPickerSlot = key.id
                    refreshHotKeys()
                }
            }
        } label: {
            Text(action.map(actionLabel) ?? "不分配动作").lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(key.name)的功能")
        .help(action.map(actionLabel) ?? "不分配动作")
    }

    private func actionItem(_ action: AgentAction, for key: RemoteKey) -> some View {
        Button { choose(action, for: key) } label: {
            if action == model.editableActions[key.id] {
                Label(actionLabel(action), systemImage: "checkmark")
            } else {
                Text(actionLabel(action))
            }
        }
    }

    private func choose(_ action: AgentAction?, for key: RemoteKey) {
        model.selectSlot(key.id)
        model.setAction(action, for: key.id)
        systemPickerSlot = nil
    }

    private var mappingFooter: some View {
        let key = RemoteKey.xiaomi.first { $0.id == model.slot } ?? RemoteKey.xiaomi[0]
        let learned = model.editableRemote?.input(for: key.id)
        let action = model.editableActions[key.id]
        return VStack(alignment: .leading, spacing: 8) {
            if systemPickerSlot == key.id { systemShortcuts(for: key) }
            if let detail = footerDetail(for: key, action: action, learned: learned) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.error != nil || model.storageError != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Label(key.name, systemImage: key.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(accent)
                if model.learning == key.id {
                    Button("取消录入") { model.cancelLearning() }.buttonStyle(.link)
                } else if learned == nil {
                    Button("录入") { model.startLearning() }
                        .disabled(!model.canReadKeys || !model.isEnabled || model.isDiagnosing)
                }
                Spacer(minLength: 4)
                if model.learning == nil, model.hasConfigurationChanges {
                    Menu {
                        Button("撤销未保存的更改") { model.discardConfigurationChanges() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("更多操作")
                }
                Button("保存") { model.saveConfigurationChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasConfigurationChanges || model.learning != nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerDetail(for key: RemoteKey, action: AgentAction?, learned: InputCode?) -> String? {
        if let error = model.storageError ?? model.error { return error }
        if model.learning == key.id { return "请按一下遥控器上的「\(key.name)」。" }
        if model.hasConfigurationChanges { return model.feedback ?? "有未保存的更改。" }
        if action == .dictation, learned?.isKeyboardF5 == true {
            return "在 ChatGPT 中将「听写快捷键」设为 F5，并解除「点按一次听写」的回车绑定。按住麦克风键说话，松开后转写，按「确定」发送。"
        }
        if let message = model.dictation.phase.message { return message }
        if action == .dictation {
            if !model.canUseAccessibility { return "开启辅助功能后才能使用 Codex 听写。" }
            if learned == nil { return "先录入遥控器上的实体键。" }
            let button = key.id == "voice" ? "麦克风键" : "「\(key.name)」键"
            return "在 Codex 对话中，按住遥控器的\(button)说话，松开后发送。"
        }
        return model.feedback
    }

    private func systemShortcuts(for key: RemoteKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let hotKeys, !hotKeys.isEmpty {
                Menu("选择已启用的快捷键") {
                    ForEach(hotKeys, id: \.self) { shortcut in
                        Button(shortcut.label) { choose(.systemShortcut(shortcut), for: key) }
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

    private func actionLabel(_ action: AgentAction) -> String {
        [action.title, action.detail].compactMap { $0 }.joined(separator: " · ")
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
