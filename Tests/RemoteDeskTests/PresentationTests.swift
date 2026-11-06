import AppKit
import SwiftUI
import Testing
@testable import RemoteDesk

@Test @MainActor
func availableMediaOrderPersistsSeparatelyFromLauncherOrder() throws {
    let suite = "media-available-order-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MediaSettings(defaults: defaults)
    settings.save(ids: ["web.youtube", "web.netflix"], custom: [])

    settings.placeAvailable("web.disneyplus", inSlot: 0)
    #expect(settings.selectedIDs == ["web.youtube", "web.netflix"])
    settings.placeAvailable("web.youtube", inSlot: 1)
    settings.placeAvailable("web.disneyplus", inSlot: 3)

    let restored = MediaSettings(defaults: defaults)
    #expect(restored.availableCandidates.prefix(3).map(\.id) == ["web.youtube", "com.apple.Music", "web.disneyplus"])
    #expect(restored.selectedIDs == ["web.netflix"])
}

@Test @MainActor
func mediaActivationAndReorderingPersistLauncherOrder() throws {
    let suite = "media-settings-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = MediaSettings(defaults: defaults)
    settings.save(ids: [], custom: [])
    #expect(settings.place("web.youtube", at: 0))
    #expect(settings.place("web.netflix", at: 1))
    #expect(settings.place("web.disneyplus", at: 1))
    #expect(settings.place("web.youtube", at: 2))
    let restored = MediaSettings(defaults: defaults)
    #expect(restored.selection().map(\.id) == ["web.disneyplus", "web.netflix", "web.youtube"])
    #expect(restored.selection().allSatisfy { $0.url.scheme == "https" })
}

@Test @MainActor
func importedModelControlsAnnotationSidesAndCapabilityStatusWithoutIdentityChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = RemoteCatalog(directory: directory.appending(path: "Installed"))
    let source = directory.appending(path: "Fixture")
    try presentationFixture(at: source, from: catalog.builtIn)
    let imported = try catalog.install(source)
    #expect(imported.id == "presentation-fixture")
    #expect(imported.manifest.capabilities.first { $0.id == "charging" }?.statusText == "设备具备 · 本地充电")

    for size in [CGSize(width: 474, height: 475), CGSize(width: 474, height: 300), CGSize(width: 600, height: 900)] {
        let guide = DeviceGuideLayout(definition: imported, viewport: size)
        let labels = guide.callouts.map(\.annotation)
        // All keys explicitly request the left rail, including those physically on the right.
        #expect(imported.layout.keys.allSatisfy { key in labels.contains { $0.id == .key(key.id) && !$0.trailing } })
        #expect(imported.layout.anchors.allSatisfy { anchor in
            labels.contains { $0.id == .capability(anchor.capability) && $0.trailing }
        })
        #expect(labels.contains { $0.id == .key("center") })
        #expect(labels.contains { $0.id == .key("south") })
        #expect(labels.count == imported.layout.keys.count + imported.layout.anchors.count)
        expectClearGuide(guide)
    }
    let restored = RemoteCatalog(directory: catalog.directory)
    let reloaded = try #require(restored.models.first { $0.id == imported.id })
    #expect(reloaded.layout.keys.allSatisfy { $0.annotationSide == .leading })
    #expect(reloaded.manifest.capabilities.first { $0.id == "charging" }?.statusText == "设备具备 · 本地充电")
}

@Test @MainActor
func legacyPackagesUsePositionBasedAnnotationsAndNeutralCapabilityStatus() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let builtIn = RemoteCatalog(directory: directory.appending(path: "Installed")).builtIn
    try presentationFixture(at: directory.appending(path: "Fixture"), from: builtIn, legacy: true)
    let definition = try RemoteDefinition.read(directory.appending(path: "Fixture"))
    let size = CGSize(width: 330, height: 475)
    let projection = ArtworkProjection(layout: definition.layout, available: size)
    let offset = CGPoint(x: (size.width - projection.size.width) / 2, y: (size.height - projection.size.height) / 2)
    let labels = DeviceGuideLayout.annotations(definition: definition, projection: projection, offset: offset)
    #expect(labels.allSatisfy { $0.trailing == ($0.anchor.x > size.width / 2) })
    #expect(definition.manifest.capabilities.allSatisfy { $0.statusText == L10n.tr("硬件具备") })
}

@Test @MainActor
func invalidPresentationFieldsAreRejectedByTheAppReader() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let builtIn = RemoteCatalog(directory: directory.appending(path: "Installed")).builtIn
    let source = directory.appending(path: "Fixture")
    try presentationFixture(at: source, from: builtIn)
    let layoutURL = source.appending(path: "layout.json")
    let original = try Data(contentsOf: layoutURL)
    for field in ["keys", "anchors"] {
        for value in ["left", "", true, 1, [String](), [String: String]()] as [Any] {
            var layout = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var entries = try #require(layout[field] as? [[String: Any]])
            entries[0]["annotationSide"] = value
            layout[field] = entries
            try JSONSerialization.data(withJSONObject: layout).write(to: layoutURL)
            #expect(throws: RemotePackageError.self) { try RemoteDefinition.read(source) }
        }
    }
    try original.write(to: layoutURL)
    let manifestURL = source.appending(path: "manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    for value in ["", "  ", true, 12, [String]()] as [Any] {
        var manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        var capabilities = try #require(manifest["capabilities"] as? [[String: Any]])
        capabilities[0]["status"] = value
        manifest["capabilities"] = capabilities
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        #expect(throws: RemotePackageError.self) { try RemoteDefinition.read(source) }
    }
}

@Test @MainActor
func legacyPresentationKeepsExistingSidesAndEveryHotspotProjection() throws {
    let builtIn = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).builtIn
    let right = Set(["voice", "ok", "down", "right", "plus", "minus", "tv"])
    #expect(builtIn.layout.visible.rect == CGRect(x: 100, y: 106, width: 525, height: 2001))
    for size in [CGSize(width: 330, height: 475), CGSize(width: 152, height: 451)] {
        let projection = ArtworkProjection(layout: builtIn.layout, available: size)
        let scale = min(size.width / 525, size.height / 2001)
        let labels = DeviceGuideLayout.annotations(definition: builtIn, projection: projection, offset: .zero)
        for key in builtIn.layout.keys {
            #expect(labels.first { $0.id == .key(key.id) }?.trailing == right.contains(key.id))
            let frame = projection.frame(for: key.shape)
            #expect(abs(frame.minX - (key.shape.x * 724 - key.shape.width * 724 / 2 - 100) * scale) < 0.000001)
            #expect(abs(frame.minY - (key.shape.y * 2172 - key.shape.height * 2172 / 2 - 106) * scale) < 0.000001)
        }
    }
}

@Test @MainActor
func guideSeparatesDPadLeadersAndUsesTheConfigurationIcons() throws {
    let builtIn = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).builtIn
    let size = CGSize(width: 474, height: 475)
    let guide = DeviceGuideLayout(definition: builtIn, viewport: size)
    let projection = ArtworkProjection(layout: builtIn.layout, available: guide.artwork.size)
    #expect(guide.size == size)
    for key in builtIn.layout.keys {
        let callout = try #require(guide.callouts.first { $0.id == .key(key.id) })
        let center = projection.center(for: key.shape)
        #expect(callout.annotation.symbol == key.symbol)
        #expect(callout.leader.first == CGPoint(x: center.x + guide.artwork.minX, y: center.y + guide.artwork.minY))
    }
    for marker in builtIn.layout.anchors {
        let callout = try #require(guide.callouts.first { $0.id == .capability(marker.capability) })
        #expect(callout.annotation.symbol == builtIn.manifest.capabilities.first { $0.id == marker.capability }?.symbol)
    }
    let confirm = try #require(guide.callouts.first { $0.id == .key("ok") })
    let right = try #require(guide.callouts.first { $0.id == .key("right") })
    #expect(abs(confirm.leader[1].y - right.leader[1].y) > 3)
    expectClearGuide(guide)
}

@Test @MainActor
func denseGuideKeepsEveryLabelAndFansOutSharedAnchors() throws {
    let builtIn = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).builtIn
    let source = try #require(builtIn.layout.keys.first)
    let keys = (0..<32).map { index in
        RemoteKey(id: "key-\(index)", name: "Key \(index)", symbol: source.symbol, shape: source.shape,
                  longPress: nil, doublePress: nil, annotationSide: .leading)
    }
    let layout = RemoteDefinition.Layout(width: builtIn.layout.width, height: builtIn.layout.height,
                                         visible: builtIn.layout.visible, keys: keys, anchors: [])
    let definition = RemoteDefinition(manifest: builtIn.manifest, layout: layout, inputs: [],
                                      front: builtIn.front, artwork: builtIn.artwork)
    let viewport = CGSize(width: 474, height: 475)
    let guide = DeviceGuideLayout(definition: definition, viewport: viewport)
    #expect(guide.size.height > viewport.height)
    #expect(guide.callouts.count == keys.count)
    #expect(Set(guide.callouts.map { $0.leader[1].y }).count == keys.count)
    expectClearGuide(guide)
}

private func expectClearGuide(_ guide: DeviceGuideLayout) {
    let bounds = CGRect(origin: .zero, size: guide.size)
    for (index, callout) in guide.callouts.enumerated() {
        #expect(bounds.contains(callout.label))
        #expect(!guide.artwork.intersects(callout.label))
        #expect(callout.leader.last?.y == callout.label.midY)
        for other in guide.callouts.dropFirst(index + 1) {
            #expect(!callout.label.intersects(other.label))
            #expect(!guideLeadersIntersect(callout.leader, other.leader), "\(callout.id) and \(other.id)")
        }
    }
}

private func guideLeadersIntersect(_ first: [CGPoint], _ second: [CGPoint]) -> Bool {
    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    return zip(first, first.dropFirst()).contains { a, b in
        zip(second, second.dropFirst()).contains { c, d in
            let sides = (cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b))
            if abs(sides.0) < 0.0001 && abs(sides.1) < 0.0001
                && abs(sides.2) < 0.0001 && abs(sides.3) < 0.0001 {
                return min(max(a.x, b.x), max(c.x, d.x)) - max(min(a.x, b.x), min(c.x, d.x)) > 0.0001
            }
            return sides.0 * sides.1 < -0.0001 && sides.2 * sides.3 < -0.0001
        }
    }
}

private func presentationFixture(at folder: URL, from definition: RemoteDefinition, legacy: Bool = false) throws {
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = definition.front.deletingLastPathComponent()
    try files.copyItem(at: definition.front, to: folder.appending(path: "front.png"))
    let names = ["ok": "center", "down": "south"]
    for file in ["manifest.json", "layout.json", "inputs.json"] {
        let data = try Data(contentsOf: source.appending(path: file))
        var json = try JSONSerialization.jsonObject(with: data)
        if file == "manifest.json" {
            var manifest = json as! [String: Any]
            manifest["id"] = "presentation-fixture"
            manifest["devices"] = [["vendor": 0x3456, "product": 0x7890]]
            manifest["capabilities"] = (manifest["capabilities"] as! [[String: Any]]).map { item in
                var item = item
                if item["id"] as? String == "usb-c" { item["id"] = "charging" }
                item["status"] = legacy ? nil : "设备具备 · 本地充电"
                return item
            }
            json = manifest
        } else if file == "layout.json" {
            var layout = json as! [String: Any]
            layout["keys"] = (layout["keys"] as! [[String: Any]]).map { key in
                var key = key
                key["id"] = names[key["id"] as! String] ?? key["id"]
                key["annotationSide"] = legacy ? nil : "leading"
                return key
            }
            layout["anchors"] = (layout["anchors"] as! [[String: Any]]).map { anchor in
                var anchor = anchor
                if anchor["capability"] as? String == "usb-c" { anchor["capability"] = "charging" }
                anchor["annotationSide"] = legacy ? nil : "trailing"
                return anchor
            }
            json = layout
        } else {
            json = (json as! [[String: Any]]).map { rule in
                var rule = rule
                rule["key"] = names[rule["key"] as! String] ?? rule["key"]
                return rule
            }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appending(path: file))
    }
}
