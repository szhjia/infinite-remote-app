import AppKit
import SwiftUI

struct SignalDiagnostics: View {
    let model: RemoteModel
    let showPermissions: () -> Void
    let showWorkspace: () -> Void
    let close: () -> Void

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("按键诊断")).font(.title2.bold())
                Spacer()
                Button(L10n.tr("完成")) { close() }.keyboardShortcut(.cancelAction)
            }
            Group {
                if let key = model.diagnosticKeyName {
                    Label(L10n.format("已验证「%@」的按下和松开", key), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).accessibilityAddTraits(.updatesFrequently)
                } else if model.canReadKeys {
                    Text(L10n.tr("请按下并松开一个实体按键。"))
                } else {
                    Text(model.connectionStatus)
                }
            }
            .foregroundStyle(.secondary)
            Text(L10n.tr("诊断中 · 动作暂停"))
                .font(.caption).foregroundStyle(.secondary)
            if model.activity.isEmpty {
                ContentUnavailableView(L10n.tr("还没有按键信号"), systemImage: "waveform.path")
            } else {
                List(model.activity) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.clock.string(from: event.time)).foregroundStyle(.secondary)
                        Text(event.text)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            HStack {
                Button(L10n.tr("清空")) { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
                Button(L10n.tr("复制信号")) {
                    NSPasteboard.general.clearContents()
                    let heading = model.config.selectedDevice.map { "\($0.name) · \($0.modelCode)" } ?? ""
                    let lines = model.activity.map { "\(Self.clock.string(from: $0.time))  \($0.text)" }
                    NSPasteboard.general.setString(([heading] + lines).joined(separator: "\n"), forType: .string)
                }.disabled(model.activity.isEmpty)
                Spacer()
                switch model.readiness {
                case .noModel, .chooseDevice:
                    Button(L10n.tr("打开工作台"), action: showWorkspace)
                case .unpaired, .ambiguous:
                    Button(L10n.tr("打开蓝牙设置")) { model.openBluetooth() }
                case .needsInputMonitoring:
                    Button(L10n.tr("设置权限"), action: showPermissions)
                case .monitorUnavailable:
                    Button(L10n.tr("重试监听")) { model.refreshPermissions() }
                default:
                    EmptyView()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 515, minHeight: 420)
    }
}
