import SwiftUI

struct DeviceArtworkGuide: View {
    let model: RemoteModel
    let showsGuide: Bool
    @State private var selectedCapability: String?

    private let laneWidth: CGFloat = 54

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let artworkSize = CGSize(width: max(1, size.width - (showsGuide ? laneWidth * 2 : 0)),
                                     height: size.height)
            let definition = model.remoteDefinition
            let projection = ArtworkProjection(layout: definition.layout, available: artworkSize)
            let offset = CGPoint(x: (size.width - projection.size.width) / 2,
                                 y: (size.height - projection.size.height) / 2)
            ZStack(alignment: .topLeading) {
                RemoteArtwork(definition: definition, highlight: { key in
                    if let press = model.hardwarePress, press.key == key {
                        return press.phase.indicatorColor.opacity(0.55)
                    }
                    return model.slot == key ? Color.accentColor.opacity(0.45) : .clear
                }, help: { L10n.format("%@ · 定位", String(describing: $0.name)) }, activate: model.selectSlot, selectedKey: model.slot,
                   selectedCapability: selectedCapability, inspectCapability: showsGuide ? { selectedCapability = $0 } : nil)
                    .frame(width: artworkSize.width, height: artworkSize.height)
                    .position(x: size.width / 2, y: size.height / 2)

                if showsGuide {
                    let labels = DeviceArtworkAnnotation.make(definition: definition, in: size, projection: projection, offset: offset)
                    ForEach(labels, id: \.identity) { label in
                        let isSelected = label.capability ? selectedCapability == label.id : model.slot == label.id
                        let rail = label.trailing ? size.width - laneWidth : laneWidth
                        let elbow = rail + (label.trailing ? -6 : 6)
                        Path { path in
                            path.move(to: CGPoint(x: rail, y: label.y))
                            path.addLine(to: CGPoint(x: elbow, y: label.y))
                            path.addLine(to: label.anchor)
                        }
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.43), lineWidth: isSelected ? 1.3 : 0.7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        labelButton(label, selected: isSelected)
                            .frame(width: laneWidth, alignment: label.trailing ? .leading : .trailing)
                            .position(x: label.trailing ? size.width - laneWidth / 2 : laneWidth / 2, y: label.y)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onChange(of: showsGuide) { _, _ in selectedCapability = nil }
        .onChange(of: model.remoteDefinition.id) { _, _ in selectedCapability = nil }
    }

    private func labelButton(_ label: DeviceArtworkAnnotation, selected: Bool) -> some View {
        Button {
            if label.capability {
                selectedCapability = label.id
            } else {
                selectedCapability = nil
                model.selectSlot(label.id)
            }
        } label: {
            Text(label.name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background {
                    if selected { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(label.name)
        .popover(isPresented: Binding(
            get: { label.capability && selectedCapability == label.id },
            set: { if !$0 && selectedCapability == label.id { selectedCapability = nil } }
        )) {
            if let capability = model.remoteDefinition.manifest.capabilities.first(where: { $0.id == label.id }) {
                DeviceCapabilityDetails(capabilities: [capability])
            }
        }
    }

}

struct DeviceArtworkAnnotation {
    let id: String
    let name: String
    let anchor: CGPoint
    let trailing: Bool
    var capability = false
    var y: CGFloat
    var identity: String { (capability ? "capability:" : "key:") + id }

    static func make(definition: RemoteDefinition, in size: CGSize,
                     projection: ArtworkProjection, offset: CGPoint) -> [Self] {
        func anchor(_ shape: Hotspot) -> CGPoint {
            let point = projection.center(for: shape)
            return CGPoint(x: offset.x + point.x, y: offset.y + point.y)
        }
        var labels = definition.layout.keys.map { key in
            let point = anchor(key.shape)
            let trailing = key.annotationSide.map { $0 == .trailing } ?? (point.x > size.width / 2)
            return Self(id: key.id, name: key.name, anchor: point, trailing: trailing, y: point.y)
        }
        for marker in definition.layout.anchors {
            guard let capability = definition.manifest.capabilities.first(where: { $0.id == marker.capability }) else { continue }
            let point = anchor(marker.shape)
            labels.append(Self(id: capability.id, name: capability.name, anchor: point,
                                     trailing: marker.annotationSide.map { $0 == .trailing } ?? (point.x > size.width / 2),
                                     capability: true, y: point.y))
        }
        return [false, true].flatMap { trailing -> [Self] in
            var lane = labels.filter { $0.trailing == trailing }.sorted { ($0.anchor.y, $0.id) < ($1.anchor.y, $1.id) }
            let spacing = min(22, max(0, size.height - 20) / CGFloat(max(1, lane.count - 1)))
            var previous: CGFloat = 10 - spacing
            for index in lane.indices {
                let bottom = size.height - 10 - CGFloat(lane.count - index - 1) * spacing
                lane[index].y = max(previous + spacing, min(lane[index].anchor.y, bottom))
                previous = lane[index].y
            }
            return lane
        }
    }
}

struct DeviceCapabilityDetails: View {
    let capabilities: [RemoteDefinition.Capability]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(capabilities) { capability in
                VStack(alignment: .leading, spacing: 4) {
                    Label(capability.name, systemImage: capability.symbol).font(.headline)
                    Text(capability.description).fixedSize(horizontal: false, vertical: true)
                    Text(capability.statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 255, alignment: .leading)
    }
}
