import AppKit
import RemoteCore
import SwiftUI

enum PermissionKind: String, Identifiable {
    case inputMonitoring, accessibility

    enum Status {
        case notAllowed, allowed, coveredByAccessibility

        var isAvailable: Bool { self != .notAllowed }
        var title: String {
            switch self {
            case .notAllowed: L10n.tr("尚未授权")
            case .allowed: L10n.tr("已授权")
            case .coveredByAccessibility: L10n.tr("可读取")
            }
        }
    }

    var id: String { rawValue }
    var title: String { L10n.tr(self == .inputMonitoring ? "输入监控" : "辅助功能") }
    var symbol: String { self == .inputMonitoring ? "keyboard" : "accessibility" }
    var explanation: String {
        L10n.tr(self == .inputMonitoring
            ? "允许无限遥控器读取你选择的遥控器按键。"
            : "允许无限遥控器模拟快捷键，并操作你选择的应用。")
    }
    @MainActor func status(in model: RemoteModel) -> Status {
        switch self {
        case .accessibility:
            return model.canUseAccessibility ? .allowed : .notAllowed
        case .inputMonitoring:
            guard model.canListen else { return .notAllowed }
            return model.canUseAccessibility ? .coveredByAccessibility : .allowed
        }
    }
    @MainActor func request(in model: RemoteModel) {
        if self == .inputMonitoring { model.requestListen() } else { model.requestAccessibility() }
    }
}

struct PermissionChecklist: View {
    let model: RemoteModel
    var beforeRequest: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                permissionRow(.accessibility)
                Divider().padding(.leading, 52)
                permissionRow(.inputMonitoring)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))

            if model.shortcutsNeedRestart {
                Label(L10n.tr("请退出并重新打开无限遥控器，以启用快捷键。"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = kind.status(in: model)
        let canRequest = kind == .accessibility || model.canUseAccessibility
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.headline)
                Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .inputMonitoring && canRequest && !status.isAvailable {
                    Text(L10n.tr("macOS 可能要求重新打开应用。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            if status.isAvailable {
                Label(status.title, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if canRequest {
                Button(L10n.tr("授权…")) {
                    beforeRequest()
                    kind.request(in: model)
                }
                .accessibilityLabel(L10n.format("授予%@权限", kind.title))
                .accessibilityHint(L10n.tr("尚未授权"))
            } else {
                Text(L10n.tr("先开启辅助功能"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

struct PermissionStepView: View {
    let kind: PermissionKind
    let model: RemoteModel
    var dismiss: (() -> Void)?

    var body: some View {
        let status = kind.status(in: model)
        VStack(spacing: 20) {
            Image(systemName: kind.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(kind.title).font(.title2.bold())
            Text(kind.explanation).multilineTextAlignment(.center)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(status.title, systemImage: status.isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.isAvailable ? Color.green : Color.secondary)
            if !status.isAvailable {
                Button(L10n.tr("打开系统设置")) { kind.request(in: model) }
                    .buttonStyle(.borderedProminent)
                Text(L10n.tr("在系统设置中开启权限，然后返回此处检查。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if kind == .accessibility && model.shortcutsNeedRestart {
                Text(L10n.tr("请退出并重新打开无限遥控器，以启用快捷键。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L10n.tr("重新检查")) { model.refreshPermissions() }
            if let dismiss {
                Button(L10n.tr(status.isAvailable ? "完成" : "稍后设置"), action: dismiss)
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
    // Existing raw values are persisted in UserDefaults.
    case welcome = 0
    case voiceDriver = 4
    case remote = 1
    case permissions = 2
    case ready = 3

    var position: Int { Self.allCases.firstIndex(of: self)! }

    func adjacent(_ offset: Int) -> Self? {
        let index = position + offset
        return Self.allCases.indices.contains(index) ? Self.allCases[index] : nil
    }

    var title: String {
        switch self {
        case .welcome: L10n.tr("无限遥控器")
        case .voiceDriver: L10n.tr("安装遥控器语音驱动")
        case .remote: L10n.tr("连接遥控器")
        case .permissions: L10n.tr("允许应用读取按键和执行动作")
        case .ready: L10n.tr("完成设置")
        }
    }

    func restored(hasModel: Bool, readiness: SetupReadiness) -> Self {
        if self == .welcome || self == .voiceDriver { return self }
        guard hasModel else { return .remote }
        if self == .permissions || self == .ready {
            return readiness.canFinish ? .ready : .permissions
        }
        return self
    }
}

struct SetupReadiness: Equatable {
    let connected: Bool
    let inputMonitoring: Bool
    let accessibility: Bool
    let canPostShortcuts: Bool
    let listening: Bool

    var hasPermissions: Bool { inputMonitoring && accessibility }
    var needsSeparateInputAuthorization: Bool { accessibility && !inputMonitoring }
    var canFinish: Bool { connected && hasPermissions && canPostShortcuts && listening }

    @MainActor init(model: RemoteModel) {
        connected = model.connected && model.readiness != .ambiguous
        inputMonitoring = model.canListen
        accessibility = model.canUseAccessibility
        canPostShortcuts = model.canPost
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
