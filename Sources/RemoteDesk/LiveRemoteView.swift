import AppKit
import RemoteCore
import SwiftUI

struct LiveRemoteView: View {
    let model: RemoteModel
    let openConfiguration: () -> Void

    var body: some View {
        VStack(spacing: model.showsXiaomiArtwork ? 6 : 10) {
            if let device = model.connectedDevice {
                if model.showsXiaomiArtwork {
                    xiaomi
                } else {
                    genericKeys
                }
                caption(device.name)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title2)
                    caption(model.config.selectedDevice?.name ?? "未选择遥控器")
                    Button(model.config.selectedDevice == nil ? "选择设备…" : "打开配置…", action: openConfiguration)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { NSApp.keyWindow?.orderOut(nil) }
    }

    private var xiaomi: some View {
        GeometryReader { geometry in
            // Leave the transparent bottom margin out of layout. Hotspots still use the full image.
            let visibleHeightFraction: CGFloat = 2107.0 / 2172.0
            let height = min(geometry.size.height / visibleHeightFraction, geometry.size.width * 3)
            let width = height / 3
            ZStack(alignment: .topLeading) {
                if let image = Self.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: width, height: height)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                ForEach(RemoteKey.xiaomi) { key in
                    if let hit = Self.hotspots[key.id] {
                        Button { model.pressVirtualKey(key.id) } label: {
                            Ellipse()
                                .fill(model.pulse == key.id ? Color.accentColor.opacity(0.50) : .clear)
                                .contentShape(Ellipse())
                                .frame(width: width * hit.width, height: height * hit.height)
                        }
                        .buttonStyle(.plain)
                        .position(x: width * hit.x, y: height * hit.y)
                        .accessibilityLabel(key.name)
                        .help(help(for: key))
                    }
                }
            }
            .frame(width: width, height: height)
            .frame(height: height * visibleHeightFraction, alignment: .top)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var genericKeys: some View {
        VStack {
            Spacer(minLength: 0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(RemoteKey.keys(for: model.layout)) { key in
                    Button { model.pressVirtualKey(key.id) } label: {
                        Image(systemName: key.symbol)
                            .frame(width: 38, height: 32)
                            .background(model.pulse == key.id ? Color.accentColor.opacity(0.35) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityLabel(key.name)
                    .help(help(for: key))
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func caption(_ name: String) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.callout.weight(.semibold)).lineLimit(2)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connected ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text([status, model.profile?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let feedback = model.feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }

    private var status: String {
        guard model.config.selectedDevice != nil else { return "请在配置中选择设备" }
        guard model.connected else { return "设备离线" }
        guard model.canReadKeys else { return "已连接 · 未监听" }
        if model.isDiagnosing { return "诊断中 · 动作暂停" }
        return model.isEnabled ? "已连接" : "已连接 · 已暂停"
    }

    private func help(for key: RemoteKey) -> String {
        guard let action = model.profile?.actions[key.id] else { return key.name }
        return [key.name, action.title, action.detail].compactMap { $0 }.joined(separator: " · ")
    }

    private static let artwork: NSImage? = {
        let packaged = Bundle.main.url(forResource: "RemoteDesk_RemoteDesk", withExtension: "bundle")
            .flatMap(Bundle.init(url:))
        let bundle = packaged ?? .module
        return bundle.url(forResource: "XiaomiRemote2Pro", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }()

    // Normalized against the complete 724 × 2172 image, including its alpha margins.
    private static let hotspots: [String: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
        "power": (0.315, 0.115, 0.166, 0.055), "voice": (0.685, 0.115, 0.166, 0.055),
        "up": (0.50, 0.192, 0.34, 0.049), "down": (0.50, 0.341, 0.34, 0.049),
        "left": (0.274, 0.265, 0.141, 0.112), "right": (0.726, 0.265, 0.141, 0.112),
        "ok": (0.50, 0.267, 0.311, 0.105),
        "back": (0.348, 0.415, 0.235, 0.078), "plus": (0.65, 0.415, 0.235, 0.078),
        "home": (0.348, 0.505, 0.235, 0.078), "minus": (0.65, 0.505, 0.235, 0.078),
        "menu": (0.348, 0.596, 0.235, 0.078), "tv": (0.65, 0.596, 0.235, 0.078)
    ]
}
