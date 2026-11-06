import AppKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceBrand: View {
    var body: some View {
        Label {
            Text(L10n.tr("无限遥控器")).font(.system(size: 13, weight: .semibold))
        } icon: {
            Image("BridgeBrand", bundle: .module)
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

struct Workspace: View {
    static let initialSize = NSSize(width: 1300, height: 720)
    static let minimumSize = NSSize(width: 1000, height: 600)
    static let sidebarWidth: CGFloat = 200

    enum Page {
        case remote, library

        var title: String {
            switch self {
            case .remote: L10n.tr("配置工作台")
            case .library: L10n.tr("遥控器资源库")
            }
        }
    }

    let model: RemoteModel
    let library: ResourceLibrary
    let showDiagnostics: () -> Void
    let showSettings: (AppSettingsPane?) -> Void
    @Binding var setupRequest: UUID?
    @Binding var page: Page
    @FocusState private var sidebarFocus: SidebarItem?
    @AppStorage("RemoteDesk.setupGuideHidden") private var setupGuideHidden = false
    @State private var showsSetupProgress = false
    @State private var showsDeviceStage = true

    private enum SidebarItem: Hashable { case setup, remote(String), library }

    private var sidebarSelection: SidebarItem {
        if page == .library { return .library }
        return model.hasRemote ? .remote(model.remoteDefinition.id) : .setup
    }

    init(model: RemoteModel, library: ResourceLibrary, page: Binding<Page>, setupRequest: Binding<UUID?> = .constant(nil),
         showDiagnostics: @escaping () -> Void, showSettings: @escaping (AppSettingsPane?) -> Void) {
        self.model = model
        self.library = library
        _page = page
        _setupRequest = setupRequest
        self.showDiagnostics = showDiagnostics
        self.showSettings = showSettings
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemPickerSlot: String?
    @State private var hotKeys: [SystemHotKey]?
    @State private var hotKeysError: String?
    @State private var sheet: SettingsSheet?
    @State private var pendingProfile: AgentProfile?
    @State private var profileName = ""
    @State private var approveImportDiscard = false
    @State private var showConfigActions = false
    @AppStorage("RemoteDesk.showDeviceGuide") private var showsDeviceGuide = true
    @State private var showsCapabilities = false
    @State private var showsCalibrationConflict = false

    private enum SettingsSheet: Identifiable {
        case profiles, name, imported(ProfileArchive), permission(PermissionKind)
        var id: String {
            switch self {
            case .profiles: "profiles"
            case .name: "name"
            case .imported: "import"
            case let .permission(kind): "permission-" + kind.id
            }
        }
    }

    private let accent = Color.accentColor
    private let mappingFont = Font.system(size: 13)

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: Self.sidebarWidth)
                Divider().ignoresSafeArea(edges: .top)
                if page == .library {
                    ResourceLibraryView(model: model, library: library, openWorkspace: openWorkspace)
                } else if model.hasRemote {
                    deviceWorkspace(width: geometry.size.width - Self.sidebarWidth - 1)
                } else {
                    emptyWorkspace
                }
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .top)
        .onDisappear { model.cancelLearning() }
        .onChange(of: setupRequest, initial: true) { _, request in
            guard request != nil else { return }
            setupGuideHidden = false
            navigate(to: .remote)
            showsSetupProgress = model.hasRemote
            setupRequest = nil
        }
        .onChange(of: model.requestedPermission) { _, permission in
            if let permission, sheet == nil { sheet = .permission(permission) }
        }
        .onChange(of: model.isEnabled) { _, enabled in
            if enabled && !model.canListen && sheet == nil { sheet = .permission(.inputMonitoring) }
        }
        .sheet(item: $sheet, onDismiss: {
            if let permission = model.requestedPermission { sheet = .permission(permission) }
        }) { presentedSheet in
            switch presentedSheet {
            case let .permission(kind):
                PermissionStepView(kind: kind, model: model) { model.requestedPermission = nil; sheet = nil }
                    .frame(width: 430)
                    .onDisappear { model.requestedPermission = nil }
            case .profiles: profilesSheet
            case .name: nameSheet(archive: nil)
            case let .imported(archive): nameSheet(archive: archive)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("我的遥控器"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .accessibilityAddTraits(.isHeader)
                    if !model.hasRemote {
                        sidebarLink(L10n.tr("开始设置"), symbol: "appletvremote.gen4", destination: .remote)
                    }
                    ForEach(model.installedModels, id: \.id) { definition in
                        let item = SidebarItem.remote(definition.id)
                        let selected = sidebarSelection == item
                        Button {
                            openWorkspace(definition.id)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                if let logo = definition.logo {
                                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                } else {
                                    Image(systemName: "appletvremote.gen4").frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                }
                                Text(definition.manifest.name).font(.callout.weight(.medium))
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selected
                                ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.hasConfigurationChanges && model.remoteDefinition.id != definition.id)
                        .focused($sidebarFocus, equals: item)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .help(definition.manifest.name)
                    }
                }
            }
            VStack(spacing: 6) {
                sidebarLink(Page.library.title, symbol: "square.grid.2x2", destination: .library)
                Button { showSettings(nil) } label: {
                    Label(L10n.tr("应用设置"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), ignoresSafeAreaEdges: .top)
    }

    private func sidebarLink(_ title: String, symbol: String, destination: Page) -> some View {
        let item: SidebarItem = destination == .library ? .library : .setup
        let selected = sidebarSelection == item
        return Button { navigate(to: destination) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(selected ? accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($sidebarFocus, equals: item)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func navigate(to destination: Page) {
        page = destination
        if sidebarFocus != nil {
            sidebarFocus = sidebarSelection
        }
    }

    private func openWorkspace(_ id: String) {
        if model.remoteDefinition.id != id { model.previewModel(id) }
        if model.remoteDefinition.id == id { navigate(to: .remote) }
    }

    private var setupChecklist: some View {
        SetupChecklist(model: model, browse: { navigate(to: .library) }, hide: {
            setupGuideHidden = true
            showsSetupProgress = false
        })
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("添加你的第一个遥控器")).font(.title2.bold())
            Text(L10n.tr("从资源库选择一个型号，或导入本地资源包。"))
                .foregroundStyle(.secondary)
            if setupGuideHidden {
                Button(L10n.tr("浏览资源库")) { navigate(to: .library) }.buttonStyle(.borderedProminent)
            } else {
                setupChecklist
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func deviceWorkspace(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(model.remoteDefinition.manifest.name).font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(showsDeviceStage ? L10n.tr("隐藏机身图") : L10n.tr("显示机身图")) {
                        showsDeviceStage.toggle()
                    }
                }
                HStack(spacing: 10) {
                    Label(model.connectionStatus, systemImage: model.canReadKeys ? "waveform" : "exclamationmark.circle")
                        .font(.callout.weight(.medium))
                    readinessAction
                    Spacer()
                    if showsSetupProgress || (!setupGuideHidden && !model.hasVerifiedInput) {
                        Button(L10n.tr("设置进度…")) { showsSetupProgress.toggle() }
                            .popover(isPresented: $showsSetupProgress) { setupChecklist.padding(12) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                if showsDeviceStage {
                    deviceStage.frame(minWidth: 0, maxWidth: .infinity)
                    Divider()
                }
                mapping
                    .frame(width: showsDeviceStage ? max(504, width * 0.55) : nil)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var readinessAction: some View {
        switch model.readiness {
        case .unpaired, .ambiguous:
            Button(L10n.tr("打开蓝牙设置")) { model.openBluetooth() }
        case .chooseDevice:
            devicePicker
        case .needsInputMonitoring:
            Button(L10n.tr("查看输入监控权限")) { sheet = .permission(.inputMonitoring) }
                .buttonStyle(.borderedProminent)
        case .monitorUnavailable:
            Button(L10n.tr("重试监听")) { model.refreshPermissions() }
        case .listening, .paused:
            Button(L10n.tr("测试按键…"), action: showDiagnostics)
                .buttonStyle(.borderedProminent)
            ConfigurationResponseSwitch(model: model)
        case .diagnosing:
            Button(L10n.tr("查看诊断…"), action: showDiagnostics)
        case .calibrating:
            Button(L10n.tr("取消校准")) { model.cancelLearning() }
        case .noModel:
            EmptyView()
        }
    }

    private var warningColor: Color {
        if colorScheme == .dark { Color(red: 1, green: 0.62, blue: 0.26) }
        else { Color(red: 0.73, green: 0.29, blue: 0) }
    }

    private var devicePicker: some View {
        Picker(L10n.tr("选择遥控器"), selection: Binding(
            get: { model.connectedDevice.flatMap { model.devicesForSelectedModel.contains($0) ? $0 : nil } },
            set: { if let id = $0 { model.selectDevice(id) } }
        )) {
            if model.connectedDevice == nil || model.connectedDevice.map(model.ambiguousDevices.contains) == true {
                Text(L10n.tr("选择遥控器")).tag(nil as DeviceID?)
            }
            ForEach(model.devicesForSelectedModel, id: \.self) { id in
                Text([id.name, id.serial].compactMap { $0 }.joined(separator: " · ")).tag(Optional(id))
            }
        }
        .labelsHidden().frame(maxWidth: 225)
    }

    private var deviceStage: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.tr("遥控器")).font(.callout.weight(.semibold))
                Spacer()
                Toggle(L10n.tr("显示设备说明"), isOn: $showsDeviceGuide)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            DeviceArtworkGuide(model: model, showsGuide: showsDeviceGuide)
                .frame(maxHeight: 475)
            VStack(spacing: 6) {
                if model.devicesForSelectedModel.count > 1 && model.readiness != .chooseDevice {
                    devicePicker
                }
                if !model.selectedAmbiguousDevices.isEmpty {
                    Text(L10n.tr("无法区分部分同型号遥控器。请在蓝牙设置中断开其中一支。"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.canReadKeys {
                    Text(L10n.tr("按键自动识别"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if showsDeviceGuide && !model.remoteDefinition.manifest.capabilities.isEmpty {
                Button(L10n.tr("硬件能力")) { showsCapabilities.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $showsCapabilities) {
                        DeviceCapabilityDetails(capabilities: model.remoteDefinition.manifest.capabilities)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity)
        .background {
            RadialGradient(colors: [accent.opacity(0.09), .clear], center: .center, startRadius: 12, endRadius: 240)
        }
    }

    private var mapping: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("按键配置")).font(.callout.weight(.semibold))
                    if let profile = model.profile {
                        Text(profile.id == AgentProfile.defaults.id ? L10n.format("%@ · 编辑后另存", profile.name) : profile.name)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button(L10n.tr("切换配置…")) { sheet = .profiles }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            Divider()
            HStack(spacing: 8) {
                Text(L10n.tr("按键名")).frame(width: 89, alignment: .leading)
                ForEach([L10n.tr("单击"), L10n.tr("双击"), L10n.tr("长按")], id: \.self) { title in
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
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
                       let systemPickerSlot, !key.actionSlots.contains(systemPickerSlot) { self.systemPickerSlot = nil }
                    proxy.scrollTo(slot)
                }
            }
            mappingFooter
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), ignoresSafeAreaEdges: .top)
    }

    private func row(_ key: RemoteKey) -> some View {
        let selected = model.slot == key.id
        let phase = model.hardwarePress.flatMap { $0.key == key.id ? $0.phase : nil }
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { model.selectSlot(key.id) } label: {
                    Label(key.name, systemImage: key.symbol)
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
            mappingControl(key, slot: key.id, gesture: L10n.tr("单击"))
            gestureCell(key, slot: key.doubleSlot, gesture: L10n.tr("双击"), supported: key.doublePress == true)
            gestureCell(key, slot: key.holdSlot, gesture: L10n.tr("长按"), supported: key.longPress == true)
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
        if supported {
            mappingControl(key, slot: slot, gesture: gesture)
                .disabled(model.editableActions[key.id] == .dictation)
        } else {
            Text(L10n.tr("不支持"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.format("%@ · %@ · 不支持", key.name, gesture))
        }
    }

    private func mappingControl(_ key: RemoteKey, slot: String, gesture: String) -> some View {
        let action = model.editableActions[slot]
        let nativeNote = slot == key.id ? "" : L10n.tr("。macOS 仍可能响应实体键的原生操作。")
        return Menu {
            actionItem(nil, for: key, slot: slot)
            Section("ChatGPT") {
                actionItem(.openApp, for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.newChat), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.sendDraft), for: key, slot: slot)
                actionItem(.shortcut(AgentProfile.stop), for: key, slot: slot)
                if slot == key.id {
                    actionItem(.dictation, for: key, slot: slot)
                        .disabled(model.editableActions[key.doubleSlot] != nil || model.editableActions[key.holdSlot] != nil)
                }
            }
            Section("macOS") {
                ForEach([AgentAction.toggleDisplays, .displaySleep, .lockScreen, .appSwitcher, .showDesktop, .volumeUp, .volumeDown, .appleMenu, .mediaChooser],
                        id: \.title) { option in
                    actionItem(option, for: key, slot: slot)
                }
                Button {
                    model.selectSlot(key.id)
                    systemPickerSlot = slot
                    refreshHotKeys()
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
        } label: {
            Label(action.map(compactActionLabel) ?? L10n.tr("无操作"), systemImage: action?.mappingSymbol ?? "minus.circle")
                .font(mappingFont)
                .foregroundStyle(action == nil ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L10n.format("%@%@的功能", String(describing: key.name), String(describing: gesture)))
        .accessibilityValue(action.map(actionLabel) ?? L10n.tr("无操作"))
        .help((action?.detail ?? action.map(actionLabel) ?? L10n.tr("无操作")) + nativeNote)
    }

    private func actionItem(_ action: AgentAction?, for key: RemoteKey, slot: String) -> some View {
        Toggle(isOn: Binding(get: { action == model.editableActions[slot] },
                             set: { _ in choose(action, for: key, slot: slot) })) {
            Label(action.map(actionLabel) ?? L10n.tr("无操作"), systemImage: action?.mappingSymbol ?? "minus.circle")
        }
    }

    private func choose(_ action: AgentAction?, for key: RemoteKey, slot: String) {
        model.selectSlot(key.id)
        model.setAction(action, for: slot)
        systemPickerSlot = nil
    }

    private var mappingFooter: some View {
        let key = model.keys.first { $0.id == model.slot } ?? model.keys[0]
        let learned = model.editableRemote?.input(for: key.id)
        let action = model.editableActions[key.id]
        let detail = footerDetail(for: key, action: action, learned: learned)
        return VStack(alignment: .leading, spacing: 0) {
            if let slot = systemPickerSlot, key.actionSlots.contains(slot) {
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
                if model.hasConfigurationChanges {
                    Label(L10n.tr("未保存的更改"), systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(L10n.tr("配置操作…")) { showConfigActions.toggle() }
                    .popover(isPresented: $showConfigActions, arrowEdge: .top) { configurationActions }
                Button(L10n.tr(model.needsProfileName ? "另存为自定义配置…" : "保存更改"), action: saveProfile)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasConfigurationChanges || model.learning != nil || model.calibrationConflict != nil)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configurationActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            WorkspacePopoverAction(L10n.tr("恢复默认")) {
                showConfigActions = false
                model.restoreDefaultActions()
            }
            WorkspacePopoverAction(L10n.tr("导出配置…")) {
                showConfigActions = false
                exportProfile()
            }
            WorkspacePopoverAction(L10n.tr("导入配置…")) {
                showConfigActions = false
                importProfile()
            }
            Divider()
            WorkspacePopoverAction(model.learning == nil ? L10n.tr("手动校准当前键…") : L10n.tr("取消校准")) {
                showConfigActions = false
                if model.learning == nil { model.startLearning() }
                else { model.cancelLearning() }
            }
            .disabled(!model.canReadKeys || !model.isEnabled || model.isDiagnosing)
            if model.hasConfigurationChanges {
                WorkspacePopoverAction(L10n.tr("撤销未保存的更改")) {
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
        if model.learning == key.id { return L10n.format("请按一下遥控器上的「%@」。", String(describing: key.name)) }
        if model.hasConfigurationChanges { return model.feedback ?? L10n.tr("有未保存的更改。") }
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

    private func systemShortcuts(for key: RemoteKey, slot: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let hotKeys, !hotKeys.isEmpty {
                Menu(L10n.tr("选择已启用的快捷键")) {
                    ForEach(hotKeys, id: \.self) { shortcut in
                        Button { choose(.systemShortcut(shortcut), for: key, slot: slot) } label: {
                            Label(shortcut.label, systemImage: "command")
                        }
                    }
                }
            } else {
                Text(hotKeysError ?? L10n.tr("没有可选择的系统快捷键。")).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(L10n.tr("打开键盘快捷键设置"), action: SystemActions.openKeyboardSettings)
                Button(L10n.tr("刷新"), action: refreshHotKeys)
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

    private var profilesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("配置列表")).font(.headline)
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
                            Text(L10n.tr("只读")).foregroundStyle(.secondary)
                        }
                        if active { Text(L10n.tr("当前使用")).foregroundStyle(accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(active)
            }
            .listStyle(.bordered)
            if let storageError = model.storageError { Text(storageError).foregroundStyle(.red) }
            Button(L10n.tr("关闭")) { sheet = nil }.keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .frame(width: 380, height: 300)
        .alert(L10n.tr("要切换配置吗？"), isPresented: Binding(
            get: { pendingProfile != nil },
            set: { if !$0 { pendingProfile = nil } }
        ), presenting: pendingProfile) { profile in
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("放弃更改并切换"), role: .destructive) { selectProfile(profile, discardingDraft: true) }
        } message: { _ in
            Text(L10n.tr("当前有未保存的更改。"))
        }
    }

    private func selectProfile(_ profile: AgentProfile, discardingDraft: Bool = false) {
        if model.selectProfile(profile.id, discardingDraft: discardingDraft) { sheet = nil }
    }

    private func nameSheet(archive: ProfileArchive?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(archive == nil ? L10n.tr("保存为自定义配置") : L10n.tr("导入为自定义配置")).font(.headline)
            TextField(L10n.tr("配置名称"), text: $profileName)
            if archive != nil && model.hasConfigurationChanges {
                Toggle(L10n.tr("放弃当前未保存的更改"), isOn: $approveImportDiscard)
            }
            if let error = model.storageError ?? model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { sheet = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存配置")) {
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
        catch { model.reportError(L10n.format("配置导出失败：%@", String(describing: error.localizedDescription))) }
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
            model.reportError(L10n.tr("无法导入该文件。请选择无限遥控器导出的配置。"))
        }
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
            Text(L10n.tr("响应遥控器")).font(.callout).accessibilityHidden(true)
            Toggle(L10n.tr("响应遥控器"), isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(L10n.tr("响应遥控器"))
        }
        .fixedSize()
        .help(L10n.tr("暂停时仍可查看按键信号"))
    }
}

extension RemoteModel.HardwarePress.Phase {
    var indicatorTitle: String {
        switch self {
        case .down: L10n.tr("按下")
        case .holding: L10n.tr("长按中")
        case .shortPress: L10n.tr("单击")
        case .doublePress: L10n.tr("双击")
        case .longPress: L10n.tr("长按")
        }
    }

    var indicatorSymbol: String {
        switch self {
        case .down: "circle.fill"
        case .holding: "waveform"
        case .shortPress, .doublePress, .longPress: "checkmark.circle.fill"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .down, .shortPress, .doublePress: .green
        case .holding, .longPress: .teal
        }
    }
}

private extension AgentAction {
    var mappingSymbol: String {
        switch self {
        case .openApp: "bubble.left"
        case .openLink: "link"
        case .shortcut, .systemShortcut: "command"
        case .foregroundKey: "keyboard"
        case .chatBar: "text.bubble"
        case .nextAgent, .appSwitcher: "rectangle.on.rectangle"
        case .dictation: "mic"
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
