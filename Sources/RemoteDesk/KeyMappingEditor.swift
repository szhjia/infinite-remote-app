import AppKit
import RemoteCore
import SwiftUI

struct KeyMappingEditor: View {
    enum Command {
        case showProfiles, saveProfile, exportProfile, importProfile
        case recordShortcut(slot: String?, provider: VoiceProvider?)
    }

    struct SystemShortcutPicker {
        let slot: String
        let hotKeys: [SystemHotKey]
        let error: String?
    }

    let model: RemoteModel
    let chatGPTIsMissing: Bool
    @Binding var guideSelection: DeviceGuideTarget?
    @Binding var shortcutPicker: SystemShortcutPicker?
    @Binding var firstKeyToConfigure: String?
    let onLocateKey: (String) -> Void
    let onCommand: (Command) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var mappingFocus: String?
    @State private var showsCalibrationConflict = false

    private let accent = Color.accentColor
    private let mappingFont = Font.system(size: 13)
    private static let mappingIcons = NSCache<NSString, NSImage>()
    private let iconWidth: CGFloat = 18
    private let iconSpacing: CGFloat = 5
    // The borderless macOS menu adds a small inset to its label.
    private let actionLeadingInset: CGFloat = 2
    private var textOffset: CGFloat { iconWidth + iconSpacing }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Group {
                            if !chatGPTIsMissing, let url = AgentRunner.appURL(model.editingApp) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                        Text(model.editingApp.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    if let profile = model.profile {
                        Text(profile.id == AgentProfile.defaults.id ? L10n.format("%@ · 编辑后另存", profile.name) : profile.name)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button(L10n.tr("配置列表")) { onCommand(.showProfiles) }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            Divider()
            HStack(spacing: 8) {
                Text(L10n.tr("按键名"))
                    .padding(.leading, textOffset)
                    .frame(width: 89, alignment: .leading)
                ForEach([L10n.tr("单击"), L10n.tr("双击"), L10n.tr("长按")], id: \.self) { title in
                    Text(title)
                        .padding(.leading, actionLeadingInset + textOffset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .frame(height: 27)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.keys) { key in
                            row(key).id(key.id)
                            if key.id != model.keys.last?.id {
                                Divider()
                                    .padding(.horizontal, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 3)
                }
                .onChange(of: model.slot) { _, slot in
                    if let key = model.keys.first(where: { $0.id == slot }),
                       let shortcutPicker, !key.actionSlots.contains(shortcutPicker.slot) { self.shortcutPicker = nil }
                    if guideSelection != .key(slot) {
                        if case .key = guideSelection { guideSelection = nil }
                        proxy.scrollTo(slot)
                    }
                }
                .onChange(of: guideSelection) { _, selection in
                    if case let .key(key) = selection { proxy.scrollTo(key) }
                }
                .onChange(of: firstKeyToConfigure, initial: true) { _, key in
                    guard let key else { return }
                    onLocateKey(key)
                    proxy.scrollTo(key)
                    mappingFocus = key
                    firstKeyToConfigure = nil
                }
            }
            mappingFooter
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ key: RemoteKey) -> some View {
        let selected = model.slot == key.id
        let phase = model.hardwarePress.flatMap { $0.key == key.id ? $0.phase : nil }
        let voiceAction = key.id == "voice" ? model.editableActions[key.id] ?? model.editableVoiceFallback : nil
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { onLocateKey(key.id) } label: {
                    HStack(spacing: iconSpacing) {
                        mappingIcon(key.symbol)
                        Text(key.name)
                    }
                        .font(mappingFont.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? accent : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                Spacer(minLength: 0)
                if let conflict = model.calibrationConflict, conflict.target == key.id {
                    conflictBadge(conflict)
                } else if let phase {
                    Image(systemName: phase.indicatorSymbol)
                        .font(.caption2)
                        .foregroundStyle(phase.indicatorColor)
                        .help(phase.indicatorTitle)
                        .accessibilityLabel(phase.indicatorTitle)
                        .frame(width: 16)
                } else {
                    Color.clear.frame(width: 16).accessibilityHidden(true)
                }
            }
            .frame(width: 89)
            if key.id == "voice", key.actionSlots.count == 1 || voiceAction?.isVoiceTrigger == true {
                editableMappingControl(key, slot: key.id, gesture: nil)
            } else {
                mappingControl(key, slot: key.id, gesture: L10n.tr("单击"))
            }
            gestureCell(key, slot: key.doubleSlot, gesture: L10n.tr("双击"),
                        supported: key.doublePress == true && voiceAction?.isVoiceTrigger != true)
            if let voiceAction, showsHoldToRecord(voiceAction) {
                holdToRecordCell(voiceAction)
            } else {
                gestureCell(key, slot: key.holdSlot, gesture: L10n.tr("长按"),
                            supported: key.longPress == true && voiceAction?.isVoiceTrigger != true)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 31)
        .background(selected ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
    }

    private func conflictBadge(_ conflict: RemoteModel.CalibrationConflict) -> some View {
        let previous = model.keys.first { $0.id == conflict.previous }?.name ?? conflict.previous
        let target = model.keys.first { $0.id == conflict.target }?.name ?? conflict.target
        return Button { showsCalibrationConflict.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(warningColor)
                .font(.caption)
                .frame(width: 16, height: 24)
        }
        .buttonStyle(.plain)
        .help(L10n.format("按键信号已绑定到「%@」", String(describing: previous)))
        .accessibilityLabel(L10n.tr("处理按键信号冲突"))
        .popover(isPresented: $showsCalibrationConflict) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.tr("按键信号冲突"), systemImage: "exclamationmark.triangle").font(.headline)
                Text(L10n.format("这个信号已绑定到「%@」。", String(describing: previous)))
                HStack {
                    Button(L10n.tr("保留原绑定")) { resolveConflict(transfer: false) }
                    Button(L10n.format("转移到「%@」", String(describing: target))) { resolveConflict(transfer: true) }
                }
            }
            .padding(14)
        }
    }

    private func resolveConflict(transfer: Bool) {
        showsCalibrationConflict = false
        model.resolveCalibrationConflict(transfer: transfer)
    }

    @ViewBuilder
    private func gestureCell(_ key: RemoteKey, slot: String, gesture: String, supported: Bool) -> some View {
        if supported, model.editableActions[key.id]?.isVoiceTrigger != true {
            mappingControl(key, slot: slot, gesture: gesture)
        } else {
            unavailableGestureCell(L10n.format("%@ · %@ · 不支持", key.name, gesture))
        }
    }

    private func unavailableGestureCell(_ accessibilityLabel: String) -> some View {
        Text("—")
            .font(mappingFont)
            .foregroundStyle(.secondary)
            .padding(.leading, actionLeadingInset + textOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityLabel)
    }

    private func mappingIcon(_ symbol: String) -> Image {
        let key = symbol as NSString
        if let cached = Self.mappingIcons.object(forKey: key) { return Image(nsImage: cached) }
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else {
            return Image(systemName: symbol)
        }
        let size = NSSize(width: iconWidth, height: iconWidth)
        let scale = min(1, size.width / source.size.width, size.height / source.size.height)
        let width = source.size.width * scale
        let height = source.size.height * scale
        let icon = NSImage(size: size, flipped: false) { bounds in
            source.draw(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height))
            return true
        }
        icon.isTemplate = true
        Self.mappingIcons.setObject(icon, forKey: key)
        return Image(nsImage: icon)
    }

    private func showsHoldToRecord(_ action: AgentAction) -> Bool {
        switch action {
        case .systemDictation: model.supportsRemoteMicrophone && model.usesRemoteMicrophone
        case .voiceShortcut(.macOS, _): model.supportsRemoteMicrophone
        case .chatGPTDraft, .dictation: !unavailableChatGPTVoice(action)
        default: false
        }
    }

    private func holdToRecordCell(_ action: AgentAction) -> some View {
        let title = L10n.tr("长按录音")
        let hint = if case .voiceShortcut(.macOS, _) = action, !model.usesRemoteMicrophone {
            L10n.tr("启用遥控器麦克风后可长按录音。")
        } else {
            ""
        }
        return Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, actionLeadingInset + textOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(hint.isEmpty ? title : hint)
            .accessibilityHint(hint)
    }

    @ViewBuilder
    private func mappingControl(_ key: RemoteKey, slot: String, gesture: String) -> some View {
        if model.isGlobalSlot(slot) {
            if slot == key.id, let action = model.editableActions[slot] {
                HStack(spacing: iconSpacing) {
                    mappingIcon(action.mappingSymbol)
                    Text(compactActionLabel(action)).lineLimit(1)
                    Text(L10n.tr("全局")).font(.caption2).foregroundStyle(.secondary)
                }
                .font(mappingFont)
                .padding(.leading, actionLeadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                unavailableGestureCell(L10n.format("%@ · %@ · 全局动作不可编辑", key.name, gesture))
            }
        } else {
            editableMappingControl(key, slot: slot, gesture: gesture)
        }
    }

    @ViewBuilder
    private func editableMappingControl(_ key: RemoteKey, slot: String, gesture: String?) -> some View {
        let action = model.editableActions[slot]
        let isVoiceSlot = slot == "voice"
        let voiceFallback = isVoiceSlot ? model.editableVoiceFallback : nil
        let effectiveAction = action ?? voiceFallback
        let missing = unavailableChatGPTVoice(effectiveAction)
        let label = missing ? L10n.tr("未安装") : effectiveAction.map(compactActionLabel) ?? L10n.tr("无操作")
        let accessibilityLabel = gesture.map { L10n.format("%@%@的功能", key.name, $0) } ?? L10n.tr("语音键功能")
        let nativeNote = slot == key.id || model.capturesKeyboard ? "" : L10n.tr("。macOS 仍可能响应实体键的原生操作。")
        Menu {
            if let voiceFallback {
                actionItem(nil, for: key, slot: slot, title: L10n.tr("使用默认语音"), symbol: voiceFallback.mappingSymbol)
            } else {
                actionItem(nil, for: key, slot: slot)
            }
            if isVoiceSlot {
                let hasGestureBindings = model.editableActions[key.doubleSlot] != nil || model.editableActions[key.holdSlot] != nil
                Section(L10n.tr("语音入口")) {
                    if model.editingApp.bundleID == AppTarget.chatGPT.bundleID && !chatGPTIsMissing {
                        actionItem(.chatGPTDraft, for: key, slot: slot)
                    }
                    actionItem(.systemDictation, for: key, slot: slot).disabled(hasGestureBindings)
                    if hasGestureBindings { Text(L10n.tr("清除语音键的双击和长按动作后可使用系统听写。")) }
                }
                Section(L10n.tr("默认语音")) {
                    Toggle(L10n.tr("默认使用 macOS 听写"), isOn: Binding(
                        get: { model.defaultVoice == .systemDictation },
                        set: { _ in model.setDefaultVoice(.systemDictation) }
                    ))
                    Button(L10n.tr("关闭默认语音")) { model.setDefaultVoice(nil) }
                        .disabled(model.defaultVoice == nil)
                }
                Menu(L10n.tr(MacDictationSetup.compatibilityTitle)) {
                    Button(L10n.tr("此应用的听写快捷键…")) { onCommand(.recordShortcut(slot: slot, provider: .macOS)) }
                        .disabled(hasGestureBindings)
                    Button(L10n.tr("默认听写快捷键…")) {
                        onCommand(.recordShortcut(slot: nil, provider: .macOS))
                    }
                }
            } else {
                standardMappingOptions(for: key, slot: slot)
            }
        } label: {
            Label {
                Text(label)
            } icon: {
                mappingIcon(effectiveAction?.mappingSymbol ?? "minus.circle")
            }
                .lineLimit(1)
                .font(mappingFont)
                .foregroundStyle(effectiveAction == nil || missing ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .disabled(model.editingCodexPreset)
        .focused($mappingFocus, equals: slot)
        .menuIndicator(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(label)
        .help((missing ? label : effectiveAction?.detail ?? label) + nativeNote)
    }

    @ViewBuilder
    private func standardMappingOptions(for key: RemoteKey, slot: String) -> some View {
        Section(L10n.tr("应用快捷键")) {
            Button(L10n.tr("录入应用快捷键…")) { onCommand(.recordShortcut(slot: slot, provider: nil)) }
            if model.editingApp.bundleID == AppTarget.chatGPT.bundleID {
                actionItem(.shortcut(AgentProfile.newChat), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.sendDraft), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.stop), for: key, slot: slot)
            }
        }
        if model.editingApp.bundleID == AppTarget.finder.bundleID {
            Section(L10n.tr("访达导航")) {
                ForEach(FinderCommand.allCases, id: \.self) { command in
                    actionItem(.finder(command), for: key, slot: slot)
                }
            }
        }
        Section("macOS") {
            ForEach([AgentAction.toggleDisplays, .displaySleep, .lockScreen, .appSwitcher, .showDesktop, .volumeUp, .volumeDown, .appleMenu, .mediaChooser],
                    id: \.title) { option in
                actionItem(option, for: key, slot: slot)
            }
            Button {
                onLocateKey(key.id)
                refreshHotKeys(for: slot)
            } label: {
                Label(L10n.tr("选择系统快捷键…"), systemImage: "command")
            }
        }
        Section(L10n.tr("键盘按键")) {
            ForEach(["up", "down", "left", "right", "ok", "back"], id: \.self) { id in
                if let action = AgentProfile.defaults.actions[id] {
                    actionItem(action, for: key, slot: slot)
                }
            }
        }
    }

    private func actionItem(_ action: AgentAction?, for key: RemoteKey, slot: String,
                            title: String? = nil, symbol: String? = nil) -> some View {
        Toggle(isOn: Binding(get: { action == model.editableActions[slot] },
                             set: { _ in choose(action, for: key, slot: slot) })) {
            Label(title ?? action.map(actionLabel) ?? L10n.tr("无操作"),
                  systemImage: symbol ?? action?.mappingSymbol ?? "minus.circle")
        }
    }

    private func choose(_ action: AgentAction?, for key: RemoteKey, slot: String) {
        onLocateKey(key.id)
        model.setAction(action, for: slot)
        shortcutPicker = nil
    }

    private var mappingFooter: some View {
        let key = model.keys.first { $0.id == model.slot } ?? model.keys[0]
        let learned = model.editableRemote?.input(for: key.id)
        let action = model.editableActions[key.id] ?? (key.id == "voice" ? model.editableVoiceFallback : nil)
        let detail = footerDetail(for: key, action: action, learned: learned)
        return VStack(alignment: .leading, spacing: 0) {
            if let shortcutPicker, key.actionSlots.contains(shortcutPicker.slot) {
                systemShortcuts(for: key, picker: shortcutPicker)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6)
            }
            if let detail {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(model.error != nil || model.storageError != nil ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if action == .systemDictation, model.learning == nil {
                        Button(L10n.tr("打开键盘设置…"), action: SystemDictation.openKeyboardSettings)
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 6)
            }
            Divider()
            HStack(spacing: 6) {
                if model.hasConfigurationChanges {
                    Label(L10n.tr("未保存的更改"), systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu(L10n.tr("配置操作")) { configurationActions }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize(horizontal: true, vertical: false)
                Button(L10n.tr(model.needsProfileName ? "另存为自定义配置…" : "保存更改"), action: { onCommand(.saveProfile) })
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasConfigurationChanges || model.learning != nil || model.calibrationConflict != nil)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var configurationActions: some View {
        Button(L10n.tr("恢复默认")) { model.restoreDefaultActions() }
            .disabled(model.editingCodexPreset)
        Button(L10n.tr("导出配置…")) { onCommand(.exportProfile) }
            .disabled(model.editingCodexPreset)
        Button(L10n.tr("导入配置…")) { onCommand(.importProfile) }
        if !model.unassignedProfiles.isEmpty {
            Menu(L10n.tr("将旧配置分配给此应用")) {
                ForEach(model.unassignedProfiles) { profile in
                    Button(profile.name) { model.assignProfile(profile.id) }
                }
            }
            .disabled(model.hasConfigurationChanges)
        }
        if model.hasConfigurationChanges {
            Divider()
            Button(L10n.tr("撤销未保存的更改")) { model.discardConfigurationChanges() }
        }
    }

    private func footerDetail(for key: RemoteKey, action: AgentAction?, learned: InputCode?) -> String? {
        if let error = model.storageError ?? model.error { return error }
        if model.learning == key.id { return L10n.format("请按一下遥控器上的「%@」。", String(describing: key.name)) }
        if model.hasConfigurationChanges { return model.feedback ?? L10n.tr("有未保存的更改。") }
        if unavailableChatGPTVoice(action) { return nil }
        if action == .chatGPTDraft {
            return L10n.tr("将 ChatGPT 的按住听写快捷键设为 F5，然后在草稿中确认转写。")
        }
        if action == .systemDictation {
            if captureUnavailable,
               learned?.hasNativeKeyboardEvent == true || model.remoteDefinition.manifest.behavior.nativeDictationKeys.contains(key.id) {
                return L10n.tr("当前设备无法可靠改绑，已保留原生按键。")
            }
            let usesRemoteMicrophone = model.usesRemoteMicrophone && model.supportsRemoteMicrophone
            return L10n.tr(usesRemoteMicrophone ? SystemDictation.remoteMicrophoneInstructions : SystemDictation.setupInstructions)
        }
        if case let .voiceShortcut(provider, shortcut) = action {
            if captureUnavailable {
                return L10n.tr("当前设备无法可靠改绑，已保留原生按键。")
            }
            return L10n.format("%@ · %@ · 转写待验证", provider.title, shortcut.label)
        }
        if case .finder = action {
            if captureUnavailable {
                return L10n.tr("当前设备无法可靠改绑，已保留原生按键。")
            }
            return model.feedback ?? L10n.tr("访达导航适用于列表和图标视图。")
        }
        if action == .dictation, learned?.isKeyboardF5 ?? (key.id == "voice") {
            return L10n.tr("在 ChatGPT 中将「听写快捷键」设为 F5，并解除「点按一次听写」的回车绑定。按住麦克风键说话，松开后转写，按「确定」发送。")
        }
        if let message = model.dictation.phase.message { return message }
        if action == .dictation {
            if !model.canUseAccessibility { return L10n.tr("开启辅助功能后才能使用 Codex 听写。") }
            let button = key.id == "voice" ? L10n.tr("麦克风键") : L10n.format("「%@」键", String(describing: key.name))
            return L10n.format("在 Codex 对话中，按住遥控器的%@说话，松开后发送。", String(describing: button))
        }
        return model.feedback
    }

    private func unavailableChatGPTVoice(_ action: AgentAction?) -> Bool {
        chatGPTIsMissing && (action == .chatGPTDraft || action == .dictation)
    }

    private var captureUnavailable: Bool {
        model.canReadKeys && model.isEnabled && !model.isDiagnosing && !model.capturesKeyboard
    }

    private func systemShortcuts(for key: RemoteKey, picker: SystemShortcutPicker) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !picker.hotKeys.isEmpty {
                Menu(L10n.tr("选择已启用的快捷键")) {
                    ForEach(picker.hotKeys, id: \.self) { shortcut in
                        Button { choose(.systemShortcut(shortcut), for: key, slot: picker.slot) } label: {
                            Label(shortcut.label, systemImage: "command")
                        }
                    }
                }
            } else {
                Text(picker.error ?? L10n.tr("没有可选择的系统快捷键。")).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(L10n.tr("打开键盘快捷键设置"), action: SystemActions.openKeyboardSettings)
                Button(L10n.tr("刷新")) { refreshHotKeys(for: picker.slot) }
            }
            .buttonStyle(.link)
        }
    }

    private func refreshHotKeys(for slot: String) {
        do {
            shortcutPicker = .init(slot: slot, hotKeys: try SystemActions.enabledHotKeys(), error: nil)
        } catch {
            shortcutPicker = .init(slot: slot, hotKeys: [], error: error.localizedDescription)
        }
    }

    private var warningColor: Color {
        if colorScheme == .dark { Color(red: 1, green: 0.62, blue: 0.26) }
        else { Color(red: 0.73, green: 0.29, blue: 0) }
    }

    private func compactActionLabel(_ action: AgentAction) -> String {
        switch action {
        case .toggleDisplays: L10n.tr("切换显示器")
        case .mediaChooser: L10n.tr("媒体选择器")
        default: actionLabel(action)
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
    let symbol: String?
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).frame(width: 14) }
                Text(title)
            }
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

private extension AgentAction {
    var mappingSymbol: String {
        switch self {
        case .openApp: "app"
        case .openFinder: "folder"
        case .openLink: "link"
        case .shortcut, .systemShortcut: "command"
        case .foregroundKey: "keyboard"
        case .chatBar: "text.bubble"
        case .nextAgent, .appSwitcher: "rectangle.on.rectangle"
        case .dictation, .chatGPTDraft, .systemDictation, .voiceShortcut: "mic"
        case .finder: "arrow.up.and.down.and.arrow.left.and.right"
        case .codexConversation(.scrollUp): "arrow.up"
        case .codexConversation(.scrollDown): "arrow.down"
        case .codexConversation(.sendTranscript): "paperplane"
        case .codexConversation(.discardConfirmation): "xmark.circle"
        case .displaySleep, .toggleDisplays: "display"
        case .appleMenu: "apple.logo"
        case .lockScreen: "lock"
        case .showDesktop: "macwindow"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .mediaChooser: "play.rectangle"
        }
    }
}
