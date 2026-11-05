import Foundation
import RemoteCore
import Testing
@testable import RemoteDesk

/// The explicit environment path exercises a ZIP exported by the independent hub.
/// Standalone app checkouts exercise the explicitly installed legacy test fixture.
@Test @MainActor
func hubPackageUsesExistingModelReaderAndRetainsDefaultKeyContract() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = RemoteCatalog(directory: directory)
    let path = ProcessInfo.processInfo.environment["REMOTE_HUB_PACKAGE_PATH"]
    let definition = try catalog.install(path.map { URL(fileURLWithPath: $0) } ?? legacyModelFixtureURL)
    #expect(definition.id == "xiaomi-2-pro")
    #expect(definition.manifest.devices == [.init(vendor: 0x2717, product: 0x32B8)])
    #expect(Set(definition.layout.keys.map(\.id)) == Set([
        "power", "voice", "up", "down", "left", "right", "ok", "back", "home", "plus", "minus", "menu", "tv"
    ]))
    #expect(definition.layout.width == 724)
    #expect(definition.layout.height == 2172)
    #expect(definition.inputs.count == catalog.builtIn.inputs.count)
    #expect(definition.accepts(actions: AgentProfile.defaults.actions))
}
