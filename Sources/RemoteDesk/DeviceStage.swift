import SwiftUI

struct DeviceStage: View {
    @Bindable var model: RemoteModel
    @Binding var selection: DeviceGuideTarget?
    let contentWidth: CGFloat
    let onLocateKey: (String) -> Void
    let showPermissions: () -> Void

    @State private var showsCapabilities = false
    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 0) {
            artworkArea.frame(width: contentWidth)
            if showsFooter {
                Divider()
                footer
            }
        }
        .frame(minWidth: contentWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RadialGradient(colors: [accent.opacity(0.09), .clear], center: .center, startRadius: 12, endRadius: 240)
        }
    }

    private var artworkArea: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.tr("遥控器")).font(.callout.weight(.semibold))
                Spacer()
                if model.readiness == .needsInputMonitoring {
                    Button(L10n.tr("设置权限")) { showPermissions() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
            DeviceArtworkGuide(model: model, selection: $selection, locateKey: onLocateKey)
                .frame(maxHeight: 475)
            VStack(spacing: 6) {
                if model.devicesForSelectedModel.count > 1 && model.readiness != .chooseDevice {
                    SetupDevicePicker(model: model)
                }
                if !model.selectedAmbiguousDevices.isEmpty {
                    Text(L10n.tr("无法区分部分同型号遥控器。请在蓝牙设置中断开其中一支。"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.canReadKeys {
                    Text(L10n.tr("按键自动识别"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            if !model.remoteDefinition.manifest.capabilities.isEmpty {
                Button(L10n.tr("硬件能力")) { showsCapabilities.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $showsCapabilities) {
                        DeviceCapabilityDetails(capabilities: model.remoteDefinition.manifest.capabilities)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }

    private var showsFooter: Bool {
        if model.supportsRemoteMicrophone { return true }
        switch model.readiness {
        case .noModel, .needsInputMonitoring, .diagnosing: return false
        default: return true
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { footerControls }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { footerControls }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var footerControls: some View {
        readinessAction
        if model.readiness == .listening || model.readiness == .paused {
            Toggle(L10n.tr("响应遥控器"), isOn: $model.isEnabled)
                .toggleStyle(DeviceFooterSwitchStyle())
                .help(L10n.tr("暂停时仍可查看按键信号"))
        }
        if model.supportsRemoteMicrophone {
            Toggle(L10n.tr("遥控器麦克风"), isOn: Binding(
                get: { model.usesRemoteMicrophone },
                set: model.setRemoteMicrophoneEnabled
            ))
            .toggleStyle(DeviceFooterSwitchStyle())
            .help(model.remoteMicrophoneStatus)
            if model.needsRemoteMicrophoneBluetooth {
                Button(L10n.tr("授权蓝牙…"), action: model.requestVoiceBluetooth)
            }
        }
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
        case .calibrating:
            Button(L10n.tr("取消校准")) { model.cancelLearning() }
        case .noModel, .needsInputMonitoring, .listening, .paused, .diagnosing:
            EmptyView()
        }
    }
}

private struct DeviceFooterSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                configuration.label.font(.callout)
                Capsule()
                    .fill(configuration.isOn ? Color.blue : Color.secondary.opacity(0.25))
                    .frame(width: 34, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                            .padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
