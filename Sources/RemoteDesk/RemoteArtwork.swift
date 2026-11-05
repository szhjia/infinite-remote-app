import SwiftUI

struct RemoteArtwork: View {
    let definition: RemoteDefinition
    let highlight: (String) -> Color
    let help: (RemoteKey) -> String
    let activate: (String) -> Void
    var selectedKey: String? = nil
    var selectedCapability: String? = nil
    var inspectCapability: ((String) -> Void)? = nil
    var onKeyPressChanged: ((String, Bool) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let projection = ArtworkProjection(layout: definition.layout, available: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.draw(Image(nsImage: definition.artwork), in: projection.image)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                ForEach(definition.layout.keys) { key in
                    region(key.shape, in: projection, name: key.name, hint: help(key),
                           fill: highlight(key.id), selected: selectedKey == key.id,
                           onPressChanged: onKeyPressChanged.map { report in { report(key.id, $0) } }) {
                        activate(key.id)
                    }
                }
                if let inspectCapability {
                    ForEach(definition.layout.anchors, id: \.capability) { anchor in
                        if let capability = definition.manifest.capabilities.first(where: { $0.id == anchor.capability }) {
                            let selected = selectedCapability == capability.id
                            region(anchor.shape, in: projection, name: capability.name, hint: L10n.tr("查看硬件说明"),
                                   fill: selected ? .accentColor.opacity(0.45) : .clear, selected: selected) {
                                inspectCapability(capability.id)
                            }
                        }
                    }
                }
            }
            .frame(width: projection.size.width, height: projection.size.height, alignment: .topLeading)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func region(_ hotspot: Hotspot, in projection: ArtworkProjection, name: String, hint: String,
                        fill: Color, selected: Bool, onPressChanged: ((Bool) -> Void)? = nil,
                        action: @escaping () -> Void) -> some View {
        let frame = projection.frame(for: hotspot)
        return ArtworkButton(hotspot: hotspot, title: name, hint: hint, fill: fill,
                             selected: selected, onPressChanged: onPressChanged, action: action)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

struct ArtworkProjection {
    let image: CGRect
    let size: CGSize

    init(layout: RemoteDefinition.Layout, available: CGSize) {
        let crop = layout.visible.rect
        let scale = min(available.width / crop.width, available.height / crop.height)
        size = CGSize(width: crop.width * scale, height: crop.height * scale)
        image = CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                       width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
    }

    func frame(for hotspot: Hotspot) -> CGRect {
        CGRect(x: image.minX + image.width * (hotspot.x - hotspot.width / 2),
               y: image.minY + image.height * (hotspot.y - hotspot.height / 2),
               width: image.width * hotspot.width, height: image.height * hotspot.height)
    }

    func center(for hotspot: Hotspot) -> CGPoint {
        let bounds = frame(for: hotspot)
        guard hotspot.kind == .sector, let angle = hotspot.angle, let inner = hotspot.innerRatio else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let radians = angle * .pi / 180
        let radius = (1 + inner) / 2
        return CGPoint(x: bounds.midX + cos(radians) * bounds.width / 2 * radius,
                       y: bounds.midY + sin(radians) * bounds.height / 2 * radius)
    }
}

struct HotspotOutline: Shape {
    let hotspot: Hotspot

    func path(in rect: CGRect) -> Path {
        switch hotspot.kind {
        case .ellipse: return Path(ellipseIn: rect)
        case .rectangle: return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 5)
        case .sector:
            guard let angle = hotspot.angle, let inner = hotspot.innerRatio else { return Path() }
            let start = Angle.degrees(angle - 45)
            let end = Angle.degrees(angle + 45)
            var path = Path()
            path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: false)
            if inner > 0 {
                path.addLine(to: CGPoint(x: inner * cos(end.radians), y: inner * sin(end.radians)))
                path.addArc(center: .zero, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            } else {
                path.addLine(to: .zero)
            }
            path.closeSubpath()
            return path.applying(CGAffineTransform(a: rect.width / 2, b: 0, c: 0, d: rect.height / 2,
                                                   tx: rect.midX, ty: rect.midY))
        }
    }
}

private struct ArtworkButton: View {
    let hotspot: Hotspot
    let title: String
    let hint: String
    let fill: Color
    let selected: Bool
    let onPressChanged: ((Bool) -> Void)?
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let onPressChanged {
                button.buttonStyle(ArtworkPressStyle(onPressChanged: onPressChanged))
            } else {
                button.buttonStyle(.plain)
            }
        }
        .focusEffectDisabled()
        .focused($focused)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(hint)
    }

    private var button: some View {
        let shape = HotspotOutline(hotspot: hotspot)
        return Button(action: action) {
            shape.fill(fill)
                .overlay {
                    if focused || selected {
                        shape.stroke(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false)
                    }
                }
                .contentShape(shape)
        }
    }
}

private struct ArtworkPressStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPressChanged(pressed) }
    }
}
