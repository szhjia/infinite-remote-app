import AppKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct Workspace: View {
    static let windowSize = NSSize(width: 1388, height: 720)
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
    @Binding var page: Page
    @Binding private var firstKeyToConfigure: String?
    @FocusState private var sidebarFocus: WorkspaceSidebar.SidebarItem?

    private var sidebarSelection: WorkspaceSidebar.SidebarItem {
        if page == .library { return .library }
        return model.hasRemote ? .remote(model.remoteDefinition.id) : .setup
    }

    init(model: RemoteModel, library: ResourceLibrary, page: Binding<Page>,
         showDiagnostics: @escaping () -> Void, showSettings: @escaping (AppSettingsPane?) -> Void,
         firstKeyToConfigure: Binding<String?> = .constant(nil)) {
        self.model = model
        self.library = library
        _page = page
        _firstKeyToConfigure = firstKeyToConfigure
        self.showDiagnostics = showDiagnostics
        self.showSettings = showSettings
    }
    @State private var sheet: SettingsSheet?
    @State private var pendingProfile: AgentProfile?
    @State private var pendingApp: AppTarget?
    @State private var appAfterSave: AppTarget?
    @State private var profileName = ""
    @State private var approveImportDiscard = false
    // Keep the active edit context when the resource library temporarily replaces the device page.
    @State private var guideSelection: DeviceGuideTarget?
    @State private var shortcutPicker: KeyMappingEditor.SystemShortcutPicker?

    private enum SettingsSheet: Identifiable {
        case profiles, name, imported(ProfileArchive), permission(PermissionKind)
        case shortcut(slot: String?, provider: VoiceProvider?)
        var id: String {
            switch self {
            case .profiles: "profiles"
            case .name: "name"
            case .imported: "import"
            case let .permission(kind): "permission-" + kind.id
            case let .shortcut(slot, provider): "shortcut-\(slot ?? "default")-\(provider?.rawValue ?? "app")"
            }
        }
    }

    private let accent = Color.accentColor

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(remotes: model.installedModels, hasRemote: model.hasRemote,
                             selectedModelID: model.remoteDefinition.id, blocksModelSwitch: model.hasConfigurationChanges,
                             selection: sidebarSelection, focus: $sidebarFocus, onNavigate: navigate,
                             onSelectRemote: openWorkspace, onShowSettings: { showSettings(nil) })
                .frame(width: Self.sidebarWidth)
            Divider().ignoresSafeArea(edges: .top)
            if page == .library {
                ResourceLibraryView(model: model, library: library, openWorkspace: openWorkspace)
            } else if model.hasRemote {
                DeviceWorkspace(model: model, guideSelection: $guideSelection, shortcutPicker: $shortcutPicker,
                                firstKeyToConfigure: $firstKeyToConfigure,
                                showDiagnostics: showDiagnostics, showPermissions: { showSettings(.permissions) },
                                onSelectApp: editApp, onAddApp: chooseApp, onEditorCommand: handleEditorCommand)
            } else {
                emptyWorkspace
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .top)
        .onDisappear { model.cancelLearning() }
        .onChange(of: sidebarFocus) { _, focus in
            // Let the workbench open with window-level focus instead of a highlighted row.
            guard focus != nil,
                  Self.focusWasAssignedAutomatically(currentEventType: NSApp.currentEvent?.type) else { return }
            sidebarFocus = nil
        }
        .onChange(of: model.remoteDefinition.id) { _, _ in guideSelection = nil }
        .onChange(of: model.editingApp.bundleID) { _, _ in shortcutPicker = nil }
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
            case let .shortcut(slot, provider): shortcutSheet(slot: slot, provider: provider)
            }
        }
        .alert(L10n.tr("要切换编辑的应用吗？"), isPresented: Binding(
            get: { pendingApp != nil }, set: { if !$0 { pendingApp = nil } }
        ), presenting: pendingApp) { app in
            Button(L10n.tr("保存并切换")) {
                if model.needsProfileName {
                    appAfterSave = app
                    saveProfile()
                } else if model.saveConfigurationChanges() {
                    model.addApp(app)
                }
            }
            Button(L10n.tr("放弃更改并切换"), role: .destructive) {
                model.addApp(app, discardingDraft: true)
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { _ in
            Text(L10n.tr("当前有未保存的更改。"))
        }
    }

    private func navigate(to destination: Page) {
        page = destination
        if sidebarFocus != nil {
            sidebarFocus = sidebarSelection
        }
    }

    /// SwiftUI gives the first focusable control the window's initial focus when the workbench
    /// becomes key. That assignment arrives while an AppKit-defined event is handled, unlike a
    /// user's Tab, arrow, or pointer action, so only focus changes outside those events are
    /// treated as the automatic initial focus that must not draw a focus ring on open.
    static func focusWasAssignedAutomatically(currentEventType: NSEvent.EventType?) -> Bool {
        guard let currentEventType else { return true }
        switch currentEventType {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            return false
        default:
            return true
        }
    }

    private func openWorkspace(_ id: String) {
        if model.remoteDefinition.id != id { model.previewModel(id) }
        if model.remoteDefinition.id == id { navigate(to: .remote) }
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("添加你的第一个遥控器")).font(.title2.bold())
            Text(L10n.tr("从资源库选择一个型号，或导入本地资源包。"))
                .foregroundStyle(.secondary)
            Button(L10n.tr("浏览资源库")) { navigate(to: .library) }.buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func editApp(_ app: AppTarget) {
        guard app.bundleID != model.editingApp.bundleID else { return }
        if model.hasConfigurationChanges { pendingApp = app }
        else { model.addApp(app) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        editApp(.init(bundleID: id, path: url.path))
    }

    private func handleEditorCommand(_ command: KeyMappingEditor.Command) {
        switch command {
        case .showProfiles: sheet = .profiles
        case .saveProfile: saveProfile()
        case .exportProfile: exportProfile()
        case .importProfile: importProfile()
        case let .recordShortcut(slot, provider): sheet = .shortcut(slot: slot, provider: provider)
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
            if let archive {
                Text(L10n.format("导入到 %@", model.importTarget(for: archive).displayName))
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField(L10n.tr("配置名称"), text: $profileName)
            if archive != nil && model.hasConfigurationChanges {
                Toggle(L10n.tr("放弃当前未保存的更改"), isOn: $approveImportDiscard)
            }
            if let error = model.storageError ?? model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { appAfterSave = nil; sheet = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存配置")) {
                    let saved: Bool
                    if let archive {
                        saved = model.importProfile(archive, as: profileName, discardingDraft: approveImportDiscard)
                    } else {
                        saved = model.saveConfigurationChanges(as: profileName)
                    }
                    if saved {
                        if let appAfterSave { model.addApp(appAfterSave) }
                        appAfterSave = nil
                        sheet = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(archive != nil && model.hasConfigurationChanges && !approveImportDiscard)
            }
        }
        .padding(18)
        .frame(width: 350)
        .onDisappear { appAfterSave = nil }
    }

    @ViewBuilder
    private func shortcutSheet(slot: String?, provider: VoiceProvider?) -> some View {
        if slot == nil && provider == .macOS {
            MacDictationSetup(model: model) { sheet = nil }
        } else if let slot {
            ShortcutSetup(
                title: provider?.title ?? L10n.tr("录入应用快捷键"),
                instructions: provider == .macOS
                    ? L10n.tr(MacDictationSetup.instructions)
                    : L10n.tr("按下目标应用使用的快捷键。"),
                needsCombination: provider != nil,
                cancel: { sheet = nil },
                save: { shortcut in
                    model.setAction(provider.map { .voiceShortcut($0, shortcut) } ?? .shortcut(shortcut), for: slot)
                    sheet = nil
                })
        }
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
