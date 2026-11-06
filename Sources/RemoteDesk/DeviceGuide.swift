import SwiftUI

struct DeviceArtworkGuide: View {
    let model: RemoteModel
    @Binding var selection: DeviceGuideTarget?
    let locateKey: (String) -> Void

    private var selectedKey: String? {
        if case let .key(id) = selection { id } else { nil }
    }

    private var selectedCapability: String? {
        if case let .capability(id) = selection { id } else { nil }
    }

    var body: some View {
        GeometryReader { geometry in
            let definition = model.remoteDefinition
            let layout = DeviceGuideLayout(definition: definition, viewport: geometry.size)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RemoteArtwork(definition: definition, highlight: { key in
                        if let press = model.hardwarePress, press.key == key {
                            return press.phase.indicatorColor.opacity(0.55)
                        }
                        return selectedKey == key ? Color.accentColor.opacity(0.32) : .clear
                    }, help: { L10n.format("%@ · 定位", $0.name) }, activate: { activate(.key($0)) },
                        selectedKey: selectedKey, selectedCapability: selectedCapability,
                        inspectCapability: { activate(.capability($0)) })
                        .frame(width: layout.artwork.width, height: layout.artwork.height)
                        .position(x: layout.artwork.midX, y: layout.artwork.midY)

                    DeviceGuideLeaders(callouts: layout.callouts, selection: selection)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    ForEach(layout.callouts) { callout in
                        label(callout)
                            .position(x: callout.label.midX, y: callout.label.midY)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func activate(_ target: DeviceGuideTarget) {
        if selection == target {
            selection = nil
        } else if case let .key(id) = target {
            locateKey(id)
        } else {
            selection = target
        }
    }

    private func label(_ callout: DeviceGuideLayout.Callout) -> some View {
        let annotation = callout.annotation
        let selected = selection == annotation.id
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button { activate(annotation.id) } label: {
            Label(annotation.name, systemImage: annotation.symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: callout.label.width, height: callout.label.height, alignment: .leading)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(selected ? Color.accentColor.opacity(0.27) : Color.primary.opacity(0.10)) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(annotation.name)
        .popover(isPresented: Binding(
            get: { if case .capability = annotation.id { selected } else { false } },
            set: { if !$0 && selection == annotation.id { selection = nil } }
        )) {
            if case let .capability(id) = annotation.id,
               let capability = model.remoteDefinition.manifest.capabilities.first(where: { $0.id == id }) {
                DeviceCapabilityDetails(capabilities: [capability])
            }
        }
    }
}

private struct DeviceGuideLeaders: View {
    let callouts: [DeviceGuideLayout.Callout]
    let selection: DeviceGuideTarget?

    var body: some View {
        Canvas { context, _ in
            for callout in callouts where callout.id != selection {
                draw(callout, selected: false, in: context)
            }
            if let selected = callouts.first(where: { $0.id == selection }) {
                draw(selected, selected: true, in: context)
            }
        }
    }

    private func draw(_ callout: DeviceGuideLayout.Callout, selected: Bool, in context: GraphicsContext) {
        let color = selected ? Color.accentColor : Color.secondary.opacity(0.72)
        let line = Path { path in path.addLines(callout.leader) }
        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: selected ? 1.4 : 0.85, lineCap: .round, lineJoin: .round))
        let anchor = callout.annotation.anchor
        let radius: CGFloat = selected ? 2.5 : 2
        let dot = Path(ellipseIn: CGRect(x: anchor.x - radius, y: anchor.y - radius,
                                         width: radius * 2, height: radius * 2))
        context.fill(dot, with: .color(selected ? color : Color(nsColor: .controlBackgroundColor)))
        context.stroke(dot, with: .color(color), lineWidth: 0.8)
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
