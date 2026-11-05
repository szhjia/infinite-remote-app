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

struct SetupProgress {
    enum Step: Int, CaseIterable { case welcome, resources, inputMonitoring, accessibility, connection }
    var step: Step = .welcome
    var canGoBack: Bool { step != .welcome }
    var isLast: Bool { step == .connection }
    mutating func advance() { step = Step(rawValue: min(step.rawValue + 1, Step.connection.rawValue))! }
    mutating func back() { step = Step(rawValue: max(0, step.rawValue - 1))! }
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

struct SetupFlowView: View {
    let model: RemoteModel
    let library: ResourceLibrary
    let finish: () -> Void
    @State private var progress = SetupProgress()
    @State private var previousDiagnosticState = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("开始使用无限遥控器")).font(.headline)
                Spacer()
                Text("\(progress.step.rawValue + 1) / \(SetupProgress.Step.allCases.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.padding(20)
            Divider()
            Group {
                switch progress.step {
                case .welcome:
                    VStack(spacing: 20) {
                        Image("BridgeBrand", bundle: .module).resizable().scaledToFit().frame(width: 64, height: 64)
                        Text(L10n.tr("用遥控器，操作 Mac。")).font(.largeTitle.bold())
                        Text(L10n.tr("添加遥控器、设置权限，再按一个键开始使用。你可以跳过任意步骤。"))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
                case .resources:
                    ResourceLibraryView(model: model, library: library, manageSources: nil)
                case .inputMonitoring:
                    PermissionStepView(kind: .inputMonitoring, model: model)
                        .frame(maxHeight: .infinity)
                case .accessibility:
                    PermissionStepView(kind: .accessibility, model: model)
                        .frame(maxHeight: .infinity)
                case .connection:
                    VStack(spacing: 18) {
                        Image(systemName: model.connected ? "checkmark.circle" : "appletvremote.gen4")
                            .font(.system(size: 42)).foregroundStyle(Color.accentColor)
                        Text(L10n.tr("连接并试一试")).font(.title2.bold())
                        Text(L10n.tr("在蓝牙设置中配对已添加的遥控器，然后按一个键。"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text(model.connectionStatus).font(.headline)
                        if let press = model.hardwarePress {
                            Label(model.keys.first(where: { $0.id == press.key })?.name ?? press.key,
                                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Button(L10n.tr("打开蓝牙设置")) { model.openBluetooth() }
                        if !model.hasRemote { Text(L10n.tr("还未添加遥控器，可稍后在资源库中添加。")) }
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { previousDiagnosticState = model.isDiagnosing; model.setDiagnosing(true) }
                    .onDisappear { model.setDiagnosing(previousDiagnosticState) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(L10n.tr("稍后设置"), action: finish).keyboardShortcut(.cancelAction)
                Spacer()
                if progress.canGoBack { Button(L10n.tr("上一步")) { progress.back() } }
                Button(L10n.tr(progress.isLast ? "开始使用" : "继续")) {
                    if progress.isLast { finish() } else { progress.advance() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 760, height: 590)
    }
}
