import AppKit
import RemoteCore
import SwiftUI

private let accent = Color(red: 0.35, green: 0.39, blue: 0.98)

struct Workspace: View {
    @Bindable var model: RemoteModel
    @State private var editor: Editor?

    private enum Editor: Identifiable {
        case profile(AgentProfile, isNew: Bool)
        case action(AgentProfile, RemoteKey)
        var id: String {
            switch self {
            case let .profile(profile, _): "profile-\(profile.id)"
            case let .action(profile, key): "action-\(profile.id)-\(key.id)"
            }
        }
    }

    private var key: RemoteKey {
        let keys = RemoteKey.keys(for: model.layout)
        return keys.first { $0.id == model.slot } ?? keys[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 253)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        workHeader
                        HStack(alignment: .top, spacing: 20) {
                            RemotePanel(model: model).frame(maxWidth: .infinity)
                            inspector.frame(width: 278)
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .tint(accent)
        .sheet(item: $editor, onDismiss: { model.isEditing = false }) { page in
            switch page {
            case let .profile(profile, isNew):
                ProfileEditor(profile: profile, isNew: isNew, canRemove: model.config.agents.count > 1,
                              save: model.saveProfile, remove: { model.removeProfile(profile.id) })
            case let .action(profile, key):
                ActionEditor(key: key, action: profile.actions[key.id], target: profile.target) { action in
                    model.setAction(action, for: key.id, in: profile.id)
                }
            }
        }
        .onDisappear { model.cancelLearning() }
    }

    private var masthead: some View {
        HStack(spacing: 12) {
            Image("BridgeBrand", bundle: .module)
                .resizable()
                .frame(width: 48, height: 48)
                .padding(-4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("遥控台").font(.system(size: 19, weight: .semibold))
                Text("REMOTE DESK").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.4).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("响应遥控器", isOn: $model.isEnabled)
                .toggleStyle(.switch).controlSize(.small)
                .help("暂停时仍可查看按键信号")
            Divider().frame(height: 24).padding(.horizontal, 3)
            HStack(spacing: 7) {
                Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.connected ? (model.canReadKeys ? "已连接" : "已连接 · 未监听") : "未连接")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.quaternary.opacity(0.55), in: Capsule())
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 13)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("设备", icon: "BridgeDevice")
                    Picker("输入设备", selection: Binding(get: { model.config.selectedDevice }, set: model.selectDevice)) {
                        Text("选择蓝牙设备").tag(Optional<DeviceID>.none)
                        if let selected = model.config.selectedDevice, !model.connected {
                            Text("\(selected.name)（离线）").tag(Optional(selected))
                        }
                        ForEach(model.devices, id: \.self) { device in
                            Text(device.name).tag(Optional(device))
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    if let selected = model.config.selectedDevice {
                        Text("HID  \(selected.modelCode)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Button("打开蓝牙设置", systemImage: "gearshape") { model.openBluetooth() }
                        .buttonStyle(.link)
                    switch model.monitorState {
                    case .permission:
                        Text("开启输入监控后，应用才能读取遥控器按键。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("开启输入监控") { model.requestListen() }
                    case let .failed(code):
                        Text("无法启动 HID 监听（\(code)）").font(.caption).foregroundStyle(.red)
                        Button("重试") { model.refreshPermissions() }
                    case .idle, .listening:
                        if model.devices.isEmpty {
                            Text("先在系统设置配对，再按一下遥控器唤醒。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionLabel("Agent 方案", icon: "BridgeProfiles")
                        Spacer()
                        Button {
                            openEditor(.profile(.init(name: "", target: nil), isNew: true))
                        } label: {
                            Image(systemName: "plus").frame(width: 21, height: 21)
                        }
                        .buttonStyle(.borderless).help("新建 Agent 方案").accessibilityLabel("新建 Agent 方案")
                    }
                    ForEach(model.config.agents) { profile in
                        agentRow(profile)
                    }
                    if let profile = model.profile {
                        Button("编辑当前方案", systemImage: "slider.horizontal.3") {
                            openEditor(.profile(profile, isNew: false))
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func agentRow(_ profile: AgentProfile) -> some View {
        let selected = model.config.activeAgentID == profile.id
        return Button {
            model.selectAgent(profile.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: agentIcon(profile.id))
                    .frame(width: 20).foregroundStyle(selected ? accent : Color.secondary)
                Text(profile.name).lineLimit(1)
                Spacer(minLength: 1)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(accent) }
            }
            .padding(.vertical, 8).padding(.horizontal, 9)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func agentIcon(_ id: String) -> String {
        switch id {
        case "chatgpt": "bubble.left"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "claude-code": "terminal"
        default: "square.dashed"
        }
    }

    private var workHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("按键映射").font(.system(size: 26, weight: .bold))
                Text("选择一个键位，录入实体按键，再为当前 Agent 分配动作。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("当前键位", icon: "BridgeMapping")
                Text(key.name).font(.title2.bold())
            }
            Divider()
            captureControls
            Divider()
            actionControls
            if let feedback = model.feedback {
                Label(feedback, systemImage: "checkmark.circle")
                    .foregroundStyle(.green).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.storageError {
                Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实体信号").font(.headline)
            if model.learning == key.id {
                Label("现在按一下遥控器的「\(key.name)」", systemImage: "waveform")
                    .foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
                Button("取消录入") { model.cancelLearning() }
            } else {
                let signal = model.config.activeRemote?.input(for: key.id)
                Text(signal?.label ?? "尚未录入")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button {
                        model.startLearning()
                    } label: {
                        Label {
                            Text(signal == nil ? "录入按键" : "重新录入")
                        } icon: {
                            Image("BridgeLearn", bundle: .module)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canReadKeys || !model.isEnabled || model.isDiagnosing)
                    if signal != nil {
                        Button("清除") { model.forget(key.id) }
                    }
                }
                if !model.connected {
                    Text("连接并选择蓝牙设备后即可录入。").font(.caption).foregroundStyle(.secondary)
                } else if model.monitorState == .permission {
                    Text("设备已连接。开启左侧的输入监控后即可录入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent 动作").font(.headline)
            if let profile = model.profile {
                Text(profile.name).font(.caption).foregroundStyle(.secondary)
                let action = profile.actions[key.id]
                Text(action?.title ?? "未分配动作").font(.body.weight(.medium))
                if let detail = action?.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Button("配置动作") { openEditor(.action(profile, key)) }
                    if let action {
                        Button {
                            model.testAction(action)
                        } label: {
                            Label {
                                Text("试运行")
                            } icon: {
                                Image("BridgeRun", bundle: .module)
                            }
                        }
                        .disabled(model.isRunning || model.learning != nil || model.isDiagnosing)
                    }
                }
                if let action, (action == .chatBar || action.requiresPost), !model.canPost {
                    Button("允许发送快捷键") { model.requestPost() }.buttonStyle(.link)
                    Text("快捷键需要「辅助功能」权限。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openEditor(_ editor: Editor) {
        model.cancelLearning()
        model.isEditing = true
        self.editor = editor
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(icon, bundle: .module)
        }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension AgentAction {
    var requiresPost: Bool { if case .shortcut = self { true } else { false } }
}
