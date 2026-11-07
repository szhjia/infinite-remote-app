import SwiftUI

struct DeviceStage: View {
    let model: RemoteModel
    @Binding var selection: DeviceGuideTarget?
    let onLocateKey: (String) -> Void
    let showPermissions: () -> Void

    @State private var showsCapabilities = false
    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.tr("遥控器")).font(.callout.weight(.semibold))
                Spacer()
                if model.readiness == .needsInputMonitoring {
                    Button(L10n.tr("设置权限")) { showPermissions() }
                        .buttonStyle(.borderedProminent)
                }
            }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity)
        .background {
            RadialGradient(colors: [accent.opacity(0.09), .clear], center: .center, startRadius: 12, endRadius: 240)
        }
    }
}
