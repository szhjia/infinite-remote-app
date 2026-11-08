import AppKit
import SwiftUI

struct ButtonTestView: View {
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
            HStack(spacing: 12) {
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
                readinessAction
            }
            signalList
            HStack(spacing: 8) {
                Button(L10n.tr("清空")) { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
                Button(L10n.tr("复制信号"), action: copySignals)
                    .disabled(model.activity.isEmpty)
                Spacer()
                Button(L10n.tr("完成"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 515, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            Text(L10n.tr("正在测试按键 · 动作暂停"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var signalList: some View {
        List(model.activity) { event in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.clock.string(from: event.time)).foregroundStyle(.secondary)
                Text(event.text)
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .overlay {
            if model.activity.isEmpty {
                Label(L10n.tr("还没有按键信号"), systemImage: "waveform.path")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var readinessAction: some View {
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

    private func copySignals() {
        NSPasteboard.general.clearContents()
        let heading = model.config.selectedDevice.map { "\($0.name) · \($0.modelCode)" } ?? ""
        let lines = model.activity.map { "\(Self.clock.string(from: $0.time))  \($0.text)" }
        NSPasteboard.general.setString(([heading] + lines).joined(separator: "\n"), forType: .string)
    }
}
