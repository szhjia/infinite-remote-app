import AppKit
import SwiftUI

struct SignalDiagnostics: View {
    let model: RemoteModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按键诊断").font(.title2.bold())
                Spacer()
                Button("完成") { close() }.keyboardShortcut(.cancelAction)
            }
            Group {
                if !model.connected {
                    Text("请先配对并选择一个蓝牙 HID 设备。")
                } else if model.canReadKeys {
                    Text("按一下「\(model.config.selectedDevice?.name ?? "")」上的实体键，查看收到的信号。")
                } else {
                    Text("设备已连接。请返回设备区域开启输入监控或重试监听。")
                }
            }
            .foregroundStyle(.secondary)
            Text("打开诊断时，实体按键不会触发 Agent 动作。")
                .font(.caption).foregroundStyle(.secondary)
            if model.activity.isEmpty {
                ContentUnavailableView("还没有按键信号", systemImage: "waveform.path")
            } else {
                List(model.activity) { event in
                    Text(event.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            HStack {
                Button("复制信号") {
                    NSPasteboard.general.clearContents()
                    let heading = model.config.selectedDevice.map { "\($0.name) · \($0.modelCode)" } ?? ""
                    NSPasteboard.general.setString(([heading] + model.activity.map(\.text)).joined(separator: "\n"), forType: .string)
                }.disabled(model.activity.isEmpty)
                Spacer()
                Button("打开蓝牙设置") { model.openBluetooth() }
            }
        }
        .padding(20)
        .frame(minWidth: 515, minHeight: 420)
    }
}
