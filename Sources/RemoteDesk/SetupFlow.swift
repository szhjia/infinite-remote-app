import AppKit
import RemoteCore
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

enum SetupStage: Int, CaseIterable {
    case welcome, remote, permissions, ready

    var title: String {
        switch self {
        case .welcome: L10n.tr("无限遥控器")
        case .remote: L10n.tr("连接遥控器")
        case .permissions: L10n.tr("允许应用读取按键和执行动作")
        case .ready: L10n.tr("完成设置")
        }
    }

    func restored(hasModel: Bool, readiness: SetupReadiness) -> Self {
        if self == .welcome { return .welcome }
        guard hasModel else { return .remote }
        // A paired remote may only report its connection after the guide is visible.
        if self == .ready && !readiness.canFinish { return .permissions }
        return self
    }
}

struct SetupReadiness: Equatable {
    let connected: Bool
    let inputMonitoring: Bool
    let accessibility: Bool
    let listening: Bool

    var hasPermissions: Bool { inputMonitoring && accessibility }
    var canFinish: Bool { connected && hasPermissions && listening }

    @MainActor init(model: RemoteModel) {
        connected = model.connected && model.readiness != .ambiguous
        inputMonitoring = PermissionKind.inputMonitoring.granted(in: model)
        accessibility = PermissionKind.accessibility.granted(in: model)
        listening = model.canReadKeys
    }
}

enum SetupStartup {
    private enum Progress: String { case inProgress, finished }

    private static let progressKey = "RemoteDesk.setupProgress"
    private static let legacySkipKey = "RemoteDesk.setupGuideHidden"
    private static let stageKey = "RemoteDesk.setupStage"

    static func requiresGuide(in defaults: UserDefaults, hasModel: Bool) -> Bool {
        switch defaults.string(forKey: progressKey).flatMap(Progress.init(rawValue:)) {
        case .inProgress: true
        case .finished: false
        case nil: !hasModel && !defaults.bool(forKey: legacySkipKey)
        }
    }

    static func begin(in defaults: UserDefaults) {
        defaults.set(Progress.inProgress.rawValue, forKey: progressKey)
    }

    static func stage(in defaults: UserDefaults, hasModel: Bool) -> SetupStage {
        guard defaults.string(forKey: progressKey) == Progress.inProgress.rawValue else { return .welcome }
        if let saved = defaults.object(forKey: stageKey) as? Int, let stage = SetupStage(rawValue: saved) { return stage }
        // Resume old in-progress guides that already added a model.
        return hasModel ? .remote : .welcome
    }

    static func save(_ stage: SetupStage, in defaults: UserDefaults) {
        guard defaults.string(forKey: progressKey) == Progress.inProgress.rawValue else { return }
        defaults.set(stage.rawValue, forKey: stageKey)
    }

    static func finish(in defaults: UserDefaults) {
        defaults.set(Progress.finished.rawValue, forKey: progressKey)
        defaults.removeObject(forKey: stageKey)
    }
}

struct SetupDevicePicker: View {
    let model: RemoteModel

    var body: some View {
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
}
