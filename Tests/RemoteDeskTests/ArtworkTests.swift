import AppKit
import SwiftUI
@testable import RemoteDesk
import Testing

@Test @MainActor
func directionRingAndNFCStayAlignedInBothWindowSizes() throws {
    let model = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).builtIn
    for size in [CGSize(width: 330, height: 475), CGSize(width: 152, height: 451)] {
        let projection = ArtworkProjection(layout: model.layout, available: size)
        func shape(_ id: String) throws -> Hotspot {
            try #require(model.layout.keys.first { $0.id == id }?.shape)
        }
        let ring = try shape("up")
        let frame = projection.frame(for: ring)
        let points = [CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.13),
                      CGPoint(x: frame.midX, y: frame.maxY - frame.height * 0.13),
                      CGPoint(x: frame.minX + frame.width * 0.13, y: frame.midY),
                      CGPoint(x: frame.maxX - frame.width * 0.13, y: frame.midY)]
        let directions = try ["up", "down", "left", "right"].map(shape)
        let paths = directions.map { HotspotOutline(hotspot: $0).path(in: projection.frame(for: $0)) }
        for (index, point) in points.enumerated() {
            #expect(paths.indices.filter { paths[$0].contains(point) } == [index])
            let effectCenter = projection.center(for: directions[index])
            #expect(paths.indices.filter { paths[$0].contains(effectCenter) } == [index])
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        #expect(paths.allSatisfy { !$0.contains(center) })
        let confirm = try shape("ok")
        #expect(HotspotOutline(hotspot: confirm).path(in: projection.frame(for: confirm)).contains(center))
        #expect(projection.center(for: confirm) == center)

        let nfc = try #require(model.layout.anchors.first { $0.capability == "nfc" }?.shape)
        let anchor = projection.frame(for: nfc)
        #expect(CGRect(origin: .zero, size: projection.size).contains(anchor))
        #expect(abs((anchor.midY - projection.image.minY) / projection.image.height - 0.748) < 0.0001)
    }
}

@Test @MainActor
func croppedArtworkRendersEvenWhenMostOfThePNGIsOutsideTheVisibleArea() throws {
    let builtIn = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).builtIn
    let layout = RemoteDefinition.Layout(width: builtIn.layout.width, height: builtIn.layout.height,
                                         visible: .init(x: 100, y: 106, width: 525, height: 240),
                                         keys: Array(builtIn.layout.keys.prefix(2)), anchors: [])
    let cropped = RemoteDefinition(manifest: builtIn.manifest, layout: layout, inputs: [],
                                   front: builtIn.front, artwork: builtIn.artwork)
    let view = RemoteArtwork(definition: cropped, highlight: { _ in .clear },
                             help: { $0.name }, activate: { _ in })
        .frame(width: 245, height: 150)
    let image = try #require(ImageRenderer(content: view).cgImage)
    let pixels = NSBitmapImageRep(cgImage: image)
    let center = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2))
    #expect(center.alphaComponent > 0.9)
}
