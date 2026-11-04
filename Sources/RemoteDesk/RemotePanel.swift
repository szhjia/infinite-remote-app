import RemoteCore
import SwiftUI

struct RemotePanel: View {
    let model: RemoteModel
    private let ink = Color(red: 0.095, green: 0.11, blue: 0.16)
    private let lavender = Color(red: 0.73, green: 0.75, blue: 1)

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                if model.config.activeRemote != nil {
                    Picker("遥控器布局", selection: Binding(get: { model.layout }, set: model.selectLayout)) {
                        Text("小米 2 Pro").tag(RemoteLayout.xiaomi2Pro)
                        Text("通用").tag(RemoteLayout.generic)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 158, alignment: .leading)
                } else {
                    Text("小米 2 Pro").font(.callout.weight(.medium))
                }
                Spacer(minLength: 0)
                Text("\(model.learnedCount) / \(RemoteKey.keys(for: model.layout).count) 已录入")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if model.layout == .xiaomi2Pro { xiaomi } else { generic }
            HStack(spacing: 12) {
                legend(lavender, "选中")
                legend(.green, "已录入")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private var xiaomi: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.33, blue: 0.43), ink, .black.opacity(0.94)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.26)))
                .shadow(color: .black.opacity(0.24), radius: 11, y: 6)
            keyButton("power", at: CGPoint(x: 37, y: 36), diameter: 32)
            keyButton("voice", at: CGPoint(x: 107, y: 36), diameter: 32)
            Circle().fill(.black.opacity(0.23))
                .overlay(Circle().strokeBorder(.white.opacity(0.13)))
                .frame(width: 116, height: 116).position(x: 72, y: 121)
            keyButton("up", at: CGPoint(x: 72, y: 80), diameter: 30, ring: true)
            keyButton("left", at: CGPoint(x: 31, y: 121), diameter: 30, ring: true)
            keyButton("ok", at: CGPoint(x: 72, y: 121), diameter: 48)
            keyButton("right", at: CGPoint(x: 113, y: 121), diameter: 30, ring: true)
            keyButton("down", at: CGPoint(x: 72, y: 162), diameter: 30, ring: true)
            Capsule().fill(.black.opacity(0.27)).frame(width: 40, height: 86).position(x: 102, y: 230)
            keyButton("back", at: CGPoint(x: 42, y: 205), diameter: 36)
            keyButton("plus", at: CGPoint(x: 102, y: 205), diameter: 36)
            keyButton("home", at: CGPoint(x: 42, y: 254), diameter: 36)
            keyButton("minus", at: CGPoint(x: 102, y: 254), diameter: 36)
            keyButton("menu", at: CGPoint(x: 42, y: 303), diameter: 36)
            keyButton("tv", at: CGPoint(x: 102, y: 303), diameter: 36)
            Text("xiaomi")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(2)
                .foregroundStyle(.white.opacity(0.63)).position(x: 72, y: 382)
                .accessibilityHidden(true)
            Capsule().fill(.white.opacity(0.22)).frame(width: 15, height: 2)
                .position(x: 72, y: 403).accessibilityHidden(true)
        }
        .frame(width: 144, height: 412)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }

    private var generic: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
            ForEach(RemoteKey.generic) { key in
                Button {
                    model.selectSlot(key.id)
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: key.symbol).font(.system(size: 18))
                        Text(key.name).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 55)
                    .background(model.slot == key.id ? lavender.opacity(0.25) : Color.secondary.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if isLearned(key.id) { dot(.green).padding(5) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.slot == key.id ? .isSelected : [])
            }
        }
    }

    private func keyButton(_ id: String, at center: CGPoint, diameter: CGFloat, ring: Bool = false) -> some View {
        let key = RemoteKey.xiaomi.first { $0.id == id }!
        let selected = model.slot == id
        let pulse = model.pulse == id
        return Button {
            model.selectSlot(id)
        } label: {
            Image(systemName: key.symbol)
                .font(.system(size: id == "ok" ? 17 : 13, weight: .semibold))
                .foregroundStyle(selected || pulse ? ink : Color.white.opacity(0.9))
                .frame(width: diameter, height: diameter)
                .background(pulse ? .green : selected ? lavender : .white.opacity(ring ? 0 : 0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(ring && !selected ? 0 : 0.13)))
                .overlay(alignment: .topTrailing) {
                    if isLearned(id) { dot(.green).padding(3) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(center)
        .help(key.name)
        .accessibilityLabel(key.name)
        .accessibilityValue(isLearned(id) ? "已录入" : "未录入")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isLearned(_ id: String) -> Bool { model.config.activeRemote?.input(for: id) != nil }
    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 6, height: 6) }
    private func legend(_ color: Color, _ title: String) -> some View { HStack(spacing: 5) { dot(color); Text(title) } }
}
