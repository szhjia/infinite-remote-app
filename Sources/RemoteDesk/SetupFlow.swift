import AppKit
import SwiftUI

enum PermissionKind: String, Identifiable {
    case inputMonitoring, accessibility
    var id: String { rawValue }
    var title: String { L10n.tr(self == .inputMonitoring ? "输入监控" : "辅助功能") }
    var symbol: String { self == .inputMonitoring ? "keyboard" : "accessibility" }
    var explanation: String {
        L10n.tr(self == .inputMonitoring
            ? "允许无限遥控器读取你选择的遥控器按键。"
            : "允许无限遥控器模拟快捷键，并操作你选择的应用。")
    }
    @MainActor func granted(in model: RemoteModel) -> Bool {
        self == .inputMonitoring ? model.canListen : model.canPost && model.canUseAccessibility
    }
    @MainActor func request(in model: RemoteModel) {
        if self == .inputMonitoring { model.requestListen() } else { model.requestPost() }
    }
}

struct PermissionStepView: View {
    let kind: PermissionKind
    let model: RemoteModel
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: kind.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(kind.title).font(.title2.bold())
            Text(kind.explanation).multilineTextAlignment(.center)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L10n.tr(kind.granted(in: model) ? "已授权" : "尚未授权"),
                  systemImage: kind.granted(in: model) ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(kind.granted(in: model) ? Color.green : Color.secondary)
            if !kind.granted(in: model) {
                Button(L10n.tr("打开系统设置")) { kind.request(in: model) }
                    .buttonStyle(.borderedProminent)
                Text(L10n.tr("在系统设置中开启权限，然后返回此处检查。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L10n.tr("重新检查")) { model.refreshPermissions() }
            if let dismiss {
                Button(L10n.tr(kind.granted(in: model) ? "完成" : "稍后设置"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

struct SetupChecklist: View {
    let model: RemoteModel
    let browse: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("遥控器设置进度")).font(.headline)
                Spacer()
                Button(L10n.tr("稍后设置"), action: hide).buttonStyle(.link)
            }
            step(L10n.tr("添加型号"), done: model.hasRemote)
            step(L10n.tr("连接并读取按键"), done: model.canReadKeys)
            step(L10n.tr("验证实体按键"), done: model.hasVerifiedInput)
            if !model.hasRemote {
                Button(L10n.tr("浏览资源库"), action: browse).buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func step(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? .primary : .secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(L10n.tr(done ? "已完成" : "待完成"))
    }
}
