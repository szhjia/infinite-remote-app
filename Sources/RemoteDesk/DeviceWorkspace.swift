import AppKit
import RemoteCore
import SwiftUI

struct DeviceWorkspace: View {
    let model: RemoteModel
    let layout: WorkspaceLayout
    @Binding var guideSelection: DeviceGuideTarget?
    @Binding var shortcutPicker: KeyMappingEditor.SystemShortcutPicker?
    @Binding var firstKeyToConfigure: String?
    let showDiagnostics: () -> Void
    let showPermissions: () -> Void
    let onSelectApp: (AppTarget) -> Void
    let onAddApp: () -> Void
    let onEditorCommand: (KeyMappingEditor.Command) -> Void

    @State private var chatGPTURL: URL?

    private var chatGPTIsMissing: Bool {
        model.editingApp.bundleID == AppTarget.chatGPT.bundleID && chatGPTURL == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.readiness != .needsInputMonitoring {
                HStack(spacing: 10) {
                    readinessAction
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 0) {
                DeviceStage(model: model, selection: $guideSelection, contentWidth: layout.deviceContentWidth,
                            onLocateKey: locateKey, showPermissions: showPermissions)
                Divider().frame(width: WorkspaceLayout.dividerWidth)
                appMapping.frame(width: layout.appMappingWidth)
            }
        }
        .onAppear(perform: refreshChatGPTInstallation)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshChatGPTInstallation()
        }
    }

    private var appMapping: some View {
        VStack(spacing: 0) {
            if chatGPTIsMissing {
                chatGPTMissingNotice
                Divider()
            }
            HStack(spacing: 0) {
                AppRail(apps: model.apps, selectedBundleID: model.editingApp.bundleID,
                        activeBundleID: model.activeBundleID, chatGPTURL: chatGPTURL,
                        onSelect: onSelectApp, onAdd: onAddApp)
                    .frame(width: layout.appRailWidth)
                Divider().opacity(0.5).frame(width: WorkspaceLayout.dividerWidth)
                KeyMappingEditor(model: model, chatGPTIsMissing: chatGPTIsMissing,
                                 guideSelection: $guideSelection, shortcutPicker: $shortcutPicker,
                                 firstKeyToConfigure: $firstKeyToConfigure,
                                 onLocateKey: locateKey, onCommand: onEditorCommand)
                    .frame(width: layout.keyMappingWidth)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), ignoresSafeAreaEdges: .top)
    }

    private var chatGPTMissingNotice: some View {
        Label(L10n.tr("未安装"), systemImage: "app.dashed")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshChatGPTInstallation() {
        chatGPTURL = AgentRunner.appURL(.chatGPT)
    }

    @ViewBuilder
    private var readinessAction: some View {
        switch model.readiness {
        case .unpaired, .ambiguous:
            Button(L10n.tr("打开蓝牙设置")) { model.openBluetooth() }
        case .chooseDevice:
            SetupDevicePicker(model: model)
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
        case .noModel, .needsInputMonitoring:
            EmptyView()
        }
    }

    private func locateKey(_ id: String) {
        model.selectSlot(id)
        guideSelection = .key(id)
    }
}
