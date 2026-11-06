import CoreGraphics

enum DeviceGuideTarget: Hashable {
    case key(String)
    case capability(String)
}

struct DeviceArtworkAnnotation: Identifiable {
    let id: DeviceGuideTarget
    let name: String
    let symbol: String
    let anchor: CGPoint
    let trailing: Bool
}

struct DeviceGuideLayout {
    static let labelHeight: CGFloat = 24
    static let labelWidth: CGFloat = 116
    static let rowPitch: CGFloat = 29
    static let inset: CGFloat = 5
    private static let artworkClearance: CGFloat = 24

    struct Callout: Identifiable {
        let annotation: DeviceArtworkAnnotation
        let label: CGRect
        // Anchor, artwork exit, label shoulder, and label edge.
        let leader: [CGPoint]
        var id: DeviceGuideTarget { annotation.id }
    }

    let size: CGSize
    let artwork: CGRect
    let callouts: [Callout]

    init(definition: RemoteDefinition, viewport: CGSize) {
        let margin = Self.inset + Self.labelWidth + Self.artworkClearance
        let projection = ArtworkProjection(layout: definition.layout,
            available: CGSize(width: max(1, viewport.width - 2 * margin), height: max(1, viewport.height - 2 * Self.inset)))
        let offset = CGPoint(x: (viewport.width - projection.size.width) / 2, y: 0)
        let annotations = Self.annotations(definition: definition, projection: projection, offset: offset)
        let trailing = annotations.filter(\.trailing)
        let leading = annotations.filter { !$0.trailing }
        let count = max(leading.count, trailing.count)
        let rows = Self.labelHeight + CGFloat(max(0, count - 1)) * Self.rowPitch + Self.inset * 2
        let canvas = CGSize(width: viewport.width, height: max(viewport.height, rows))
        size = canvas
        artwork = CGRect(x: offset.x, y: (canvas.height - projection.size.height) / 2,
                         width: projection.size.width, height: projection.size.height)
        let deltaY = artwork.minY
        let points = annotations.map { CGPoint(x: $0.anchor.x, y: $0.anchor.y + deltaY) }
        let leftExit = artwork.minX - 5
        let rightExit = artwork.maxX + 5
        let distances = zip(points, annotations).map { point, annotation in
            (annotation.trailing ? rightExit : leftExit) - point.x
        }
        let departure = Self.departureAngle(points: points, distances: distances, height: canvas.height)

        callouts = [false, true].flatMap { isTrailing in
            Self.placeLane(annotations: isTrailing ? trailing : leading, deltaY: deltaY,
                           exitX: isTrailing ? rightExit : leftExit, slope: departure.slope,
                           branchSpread: min(1.5, departure.clearance / 3), size: canvas)
        }
    }

    static func annotations(definition: RemoteDefinition, projection: ArtworkProjection,
                            offset: CGPoint) -> [DeviceArtworkAnnotation] {
        let midX = offset.x + projection.size.width / 2
        func annotation(id: DeviceGuideTarget, name: String, symbol: String, shape: Hotspot,
                        side: RemoteDefinition.AnnotationSide?) -> DeviceArtworkAnnotation {
            let point = projection.center(for: shape)
            let anchor = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            return DeviceArtworkAnnotation(id: id, name: name, symbol: symbol, anchor: anchor,
                trailing: side.map { $0 == .trailing } ?? (anchor.x > midX))
        }

        let keys = definition.layout.keys.map {
            annotation(id: .key($0.id), name: $0.name, symbol: $0.symbol, shape: $0.shape, side: $0.annotationSide)
        }
        let capabilities = Dictionary(uniqueKeysWithValues: definition.manifest.capabilities.map { ($0.id, $0) })
        return keys + definition.layout.anchors.compactMap { marker in
            guard let capability = capabilities[marker.capability] else { return nil }
            return annotation(id: .capability(capability.id), name: capability.name, symbol: capability.symbol,
                              shape: marker.shape, side: marker.annotationSide)
        }
    }

    // Parallel departures cannot cross inside the artwork. Pick an angle that also
    // separates near-collinear departures, such as Confirm and Right on a D-pad.
    private static func departureAngle(points: [CGPoint], distances: [CGFloat],
                                       height: CGFloat) -> (slope: CGFloat, clearance: CGFloat) {
        let uniquePoints = points.reduce(into: [CGPoint]()) { unique, point in
            if !unique.contains(point) { unique.append(point) }
        }
        var low: CGFloat = -0.36
        var high: CGFloat = 0.36
        for (point, distance) in zip(points, distances) where distance != 0 {
            let top = (1 - point.y) / distance
            let bottom = (height - 1 - point.y) / distance
            low = max(low, min(top, bottom))
            high = min(high, max(top, bottom))
        }
        func clearance(at slope: CGFloat) -> CGFloat {
            let intercepts = uniquePoints.map { $0.y - $0.x * slope }.sorted()
            return zip(intercepts, intercepts.dropFirst()).map { $1 - $0 }.min() ?? 4
        }

        var best: (slope: CGFloat, clearance: CGFloat) = (0, -1)
        let magnitudes: [CGFloat] = [0.20, 0.24, 0.16, 0.28, 0.12, 0.32, 0.08, 0.36, 0.04, 0.02, 0.01]
        let slopes: [CGFloat] = magnitudes.flatMap { [-$0, $0] } + [0]
        for slope in slopes where slope >= low && slope <= high {
            let gap = clearance(at: slope)
            if gap >= 3 { return (slope, gap) }
            if gap > best.clearance { best = (slope, gap) }
        }
        if best.clearance > 0.00001 { return best }

        // If the preferred angles all align a pair, find an angle between
        // their alignment slopes. Finite distinct points exclude only finite angles.
        var limits = [low, high]
        for (index, point) in uniquePoints.enumerated() {
            for other in uniquePoints.dropFirst(index + 1) where other.x != point.x {
                let slope = (other.y - point.y) / (other.x - point.x)
                if slope > low && slope < high { limits.append(slope) }
            }
        }
        limits.sort()
        if let gap = zip(limits, limits.dropFirst()).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) {
            let slope = (gap.0 + gap.1) / 2
            let spacing = clearance(at: slope)
            if spacing > best.clearance { return (slope, spacing) }
        }
        return (best.slope, max(0, best.clearance))
    }

    private static func placeLane(annotations: [DeviceArtworkAnnotation], deltaY: CGFloat,
                                  exitX: CGFloat, slope: CGFloat, branchSpread: CGFloat, size: CGSize) -> [Callout] {
        guard let first = annotations.first else { return [] }
        let trailing = first.trailing
        let labelX = trailing ? size.width - inset - labelWidth : inset
        let edgeX = trailing ? labelX : labelX + labelWidth
        let shoulderX = edgeX + (trailing ? -9 : 9)
        let departures = annotations.enumerated().map { index, item in
            let anchor = CGPoint(x: item.anchor.x, y: item.anchor.y + deltaY)
            let y = anchor.y + (exitX - anchor.x) * slope
            return (index: index, item: item, anchor: anchor, exitY: y)
        }.sorted { ($0.exitY, $0.index) < ($1.exitY, $1.index) }

        // Coincident physical anchors may share a dot, but their lines should fan out.
        var exitYs = departures.map(\.exitY)
        var start = 0
        while start < exitYs.count {
            let y = exitYs[start]
            var end = start + 1
            while end < exitYs.count && exitYs[end] == y { end += 1 }
            if end - start > 1 {
                let above = start > 0 ? y - exitYs[start - 1] : y
                let below = end < exitYs.count ? exitYs[end] - y : size.height - y
                let spread = min(branchSpread, above / 3, below / 3)
                for index in start..<end {
                    exitYs[index] += spread * (2 * CGFloat(index - start) / CGFloat(end - start - 1) - 1)
                }
            }
            start = end
        }

        // The exits and label centers are in the same order, so the outside
        // sections cannot cross either. All final segments stop at the label edge.
        let centers = spacedCenters(near: exitYs, height: size.height)
        return departures.indices.map { index in
            let departure = departures[index]
            let center = centers[index]
            let item = departure.item
            let annotation = DeviceArtworkAnnotation(id: item.id, name: item.name, symbol: item.symbol,
                                                     anchor: departure.anchor, trailing: trailing)
            return Callout(annotation: annotation,
                label: CGRect(x: labelX, y: center - labelHeight / 2, width: labelWidth, height: labelHeight),
                leader: [departure.anchor, CGPoint(x: exitX, y: exitYs[index]),
                         CGPoint(x: shoulderX, y: center), CGPoint(x: edgeX, y: center)])
        }
    }

    // Merge crowded neighbors into evenly spaced groups, then clamp each group
    // as a unit. This distributes movement above and below a cluster of anchors.
    private static func spacedCenters(near targets: [CGFloat], height: CGFloat) -> [CGFloat] {
        var groups: [(sum: CGFloat, count: Int)] = []
        for (index, target) in targets.enumerated() {
            groups.append((target - CGFloat(index) * rowPitch, 1))
            while groups.count > 1 {
                let right = groups[groups.count - 1]
                let left = groups[groups.count - 2]
                guard left.sum / CGFloat(left.count) > right.sum / CGFloat(right.count) else { break }
                groups.removeLast(2)
                groups.append((left.sum + right.sum, left.count + right.count))
            }
        }
        let top = inset + labelHeight / 2
        let bottom = max(top, height - top - CGFloat(max(0, targets.count - 1)) * rowPitch)
        return groups.flatMap { group in
            Array(repeating: min(bottom, max(top, group.sum / CGFloat(group.count))), count: group.count)
        }.enumerated().map { index, origin in origin + CGFloat(index) * rowPitch }
    }
}
