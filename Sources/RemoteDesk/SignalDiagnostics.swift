import AppKit
import SwiftUI

struct SignalDiagnostics: View {
    let model: RemoteModel
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
                Text("按键诊断").font(.title2.bold())
                Spacer()
                Button("完成") { close() }.keyboardShortcut(.cancelAction)
            }
            Group {
                if !model.connected {
                    Text("请先在 macOS 蓝牙设置中配对已适配的遥控器。")
                } else if model.canReadKeys {
                    Text("按住后松开「\(model.config.selectedDevice?.name ?? "")」上的实体键，查看按下与松开信号。")
                } else {
                    Text("设备已连接。请返回配置页开启输入监控或重试监听。")
                }
            }
            .foregroundStyle(.secondary)
            Text("最新在上。打开诊断时，实体按键不会触发动作。")
                .font(.caption).foregroundStyle(.secondary)
            if model.activity.isEmpty {
                ContentUnavailableView("还没有按键信号", systemImage: "waveform.path")
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
                Button("清空") { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
                Button("复制信号") {
                    NSPasteboard.general.clearContents()
                    let heading = model.config.selectedDevice.map { "\($0.name) · \($0.modelCode)" } ?? ""
                    let lines = model.activity.map { "\(Self.clock.string(from: $0.time))  \($0.text)" }
                    NSPasteboard.general.setString(([heading] + lines).joined(separator: "\n"), forType: .string)
                }.disabled(model.activity.isEmpty)
                Spacer()
                Button("打开蓝牙设置") { model.openBluetooth() }
            }
        }
        .padding(20)
        .frame(minWidth: 515, minHeight: 420)
    }
}
