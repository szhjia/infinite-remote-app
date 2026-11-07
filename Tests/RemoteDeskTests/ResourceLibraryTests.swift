import CryptoKit
import Foundation
import RemoteCore
import Testing
import AppKit
import SwiftUI
@testable import RemoteDesk

private final class LibraryURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let data: Data }
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    private static let lock = NSLock()
    static func register(_ url: URL, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }; replies[url.absoluteString] = reply
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixtures.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let reply = Self.replies[request.url!.absoluteString]
        Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(reply.data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class LibraryInputSource: RemoteInputSource {
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onMonitorState: (InputMonitorState) -> Void = { _ in }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void = { _, _ in }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void = { _ in }
    var selectedDevice: DeviceID?
    var state: InputMonitorState = .permission
    func refresh() -> InputMonitorState { state }
}

private func librarySession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LibraryURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func resourceFixture() -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures/Packages/xiaomi-2-pro")
}

private func libraryArchive(_ directory: URL) throws -> Data {
    let archive = directory.appending(path: "fixture.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = resourceFixture().deletingLastPathComponent()
    process.arguments = ["-q", "-r", archive.path, "xiaomi-2-pro"]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try Data(contentsOf: archive)
}

private func sourceCatalog(_ archive: Data, id: String = "xiaomi-2-pro", release: String = "1.0.0",
                           hash: String? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "formatVersion": 2, "id": "test-source", "name": ["en": "Test source", "zh": "测试源"],
        "models": [["id": id, "release": release, "name": ["en": "Xiaomi Remote", "zh": "小米遥控器"],
                    "summary": ["en": "Test remote", "zh": "测试遥控器"], "package": "remote.zip",
                    "packageSHA256": hash ?? SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()]]
    ])
}

private func temporaryLibraryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "library-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test @MainActor
func resourceLibraryInstallsVerifiedZIPAndRetainsCacheOfflineAndAfterSourceRemoval() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try await Task.detached { try libraryArchive(directory) }.value
    let session = librarySession(); defer { session.invalidateAndCancel() }
    let library = ResourceLibrary(directory: directory.appending(path: "Library"), session: session)
    let url = URL(string: "https://fixtures.example/\(UUID().uuidString)/catalog.json")!
    let id = try library.addSource(url.absoluteString)
    LibraryURLProtocol.register(url, .init(status: 200, data: try sourceCatalog(data)))
    LibraryURLProtocol.register(url.deletingLastPathComponent().appending(path: "remote.zip"), .init(status: 200, data: data))
    await library.refresh(id)
    let source = try #require(library.sources.first { $0.id == id })
    let listing = try #require(source.catalog?.models.first)
    let model = RemoteModel(hid: LibraryInputSource(), storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })
    #expect(!model.hasRemote)
    await library.install(listing, from: source, into: model)
    #expect(library.errors[id + ":" + listing.id] == nil)
    #expect(model.installedModels.count == 1)
    #expect(model.installedOwner(of: listing.id) == id)
    #expect(model.remoteDefinition.id == listing.id)
    #expect(model.remoteDefinition.manifest.name == model.remoteDefinition.manifest.localizedName.resolve())
    #expect(model.remoteDefinition.logo != nil)
    LibraryURLProtocol.register(url, .init(status: 503, data: Data()))
    await library.refresh(id)
    #expect(library.errors[id] != nil)
    #expect(library.sources.first { $0.id == id }?.catalog?.models.count == 1)
    let restored = ResourceLibrary(directory: directory.appending(path: "Library"), session: session)
    #expect(restored.sources.first { $0.id == id }?.catalog?.models.first?.id == listing.id)
    try library.removeSource(id)
    #expect(model.installedModels.count == 1)
    #expect(try library.addSource(url.absoluteString) == id)
}

@Test(arguments: ["hash", "identity", "release"]) @MainActor
func subscriptionMismatchNeverInstallsOrReplacesResources(_ mismatch: String) async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try await Task.detached { try libraryArchive(directory) }.value
    let session = librarySession(); defer { session.invalidateAndCancel() }
    let library = ResourceLibrary(directory: directory.appending(path: "Library"), session: session)
    let url = URL(string: "https://fixtures.example/\(UUID().uuidString)/catalog.json")!
    let id = try library.addSource(url.absoluteString)
    let catalog = try sourceCatalog(data, id: mismatch == "identity" ? "wrong-remote" : "xiaomi-2-pro",
                                    release: mismatch == "release" ? "2.0.0" : "1.0.0",
                                    hash: mismatch == "hash" ? String(repeating: "0", count: 64) : nil)
    LibraryURLProtocol.register(url, .init(status: 200, data: catalog))
    LibraryURLProtocol.register(url.deletingLastPathComponent().appending(path: "remote.zip"), .init(status: 200, data: data))
    await library.refresh(id)
    let source = try #require(library.sources.first { $0.id == id })
    let listing = try #require(source.catalog?.models.first)
    let model = RemoteModel(hid: LibraryInputSource(), storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })
    await library.install(listing, from: source, into: model)
    #expect(model.installedModels.isEmpty)
    #expect(library.errors[id + ":" + listing.id] != nil)
}

@Test @MainActor
func emptyModelNeedsAResourceEvenWhenPermissionsAreGranted() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = LibraryInputSource()
    var allowed = false
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            permissions: .init(postEvents: { allowed }, accessibility: { allowed }), runAction: { _, _ in })
    #expect(model.installedModels.isEmpty)
    #expect(model.keys.isEmpty)
    #expect(!model.hasRemote)
    #expect(model.readiness == .noModel)
    #expect(model.profile == nil)
    #expect(PermissionKind.inputMonitoring.status(in: model) == .notAllowed)
    #expect(PermissionKind.accessibility.status(in: model) == .notAllowed)
    input.state = .idle; allowed = true; model.refreshPermissions()
    #expect(PermissionKind.inputMonitoring.status(in: model) == .coveredByAccessibility)
    #expect(PermissionKind.accessibility.status(in: model) == .allowed)
    #expect(model.readiness == .noModel)
    input.state = .permission; allowed = false; model.refreshPermissions()
    #expect(PermissionKind.inputMonitoring.status(in: model) == .notAllowed)
    #expect(PermissionKind.accessibility.status(in: model) == .notAllowed)
}

@Test @MainActor
func invalidSourcesAndCorruptSettingsCannotOverwritePersistedState() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ResourceLibrary(directory: directory)
    for url in ["http://example.com/catalog.json", "file:///tmp/catalog.json", "https://user:secret@example.com/catalog.json", "https://example.com/catalog.json#fragment"] {
        #expect(throws: (any Error).self) { try library.addSource(url) }
    }
    let original = Data("unreadable subscriptions".utf8)
    try original.write(to: directory.appending(path: "subscriptions.json"))
    let broken = ResourceLibrary(directory: directory)
    #expect(broken.storageError != nil)
    #expect(throws: (any Error).self) { try broken.addSource("https://example.com/catalog.json") }
    #expect(try Data(contentsOf: directory.appending(path: "subscriptions.json")) == original)
}

@Test @MainActor
func missingDefaultSourceIsRestoredAndCannotBeEditedOrRemoved() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://fixtures.example/custom/catalog.json")!
    let custom = RemoteSubscription(id: ResourceLibrary.sourceID(for: url), url: url)
    try JSONEncoder().encode([custom]).write(to: directory.appending(path: "subscriptions.json"))

    let library = ResourceLibrary(directory: directory)
    #expect(library.sources.map(\.url) == [ResourceLibrary.officialURL, url])
    let official = try #require(library.sources.first { $0.isDefault })
    #expect(throws: (any Error).self) { try library.removeSource(official.id) }
    #expect(throws: (any Error).self) { try library.updateSource(official.id, url: "https://fixtures.example/new/catalog.json") }
    try library.removeSource(custom.id)
    #expect(ResourceLibrary(directory: directory).sources.map(\.id) == [official.id])
}

@Test @MainActor
func editingSourcePersistsItsNewEndpointWithoutInheritingTheOldCatalog() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ResourceLibrary(directory: directory, session: librarySession())
    let oldURL = URL(string: "https://fixtures.example/edit-old/catalog.json")!
    let newURL = URL(string: "https://fixtures.example/edit-new/catalog.json")!
    let oldID = try library.addSource(oldURL.absoluteString)
    let otherID = try library.addSource("https://fixtures.example/edit-other/catalog.json")
    let catalog = try sourceCatalog(Data())
    LibraryURLProtocol.register(oldURL, .init(status: 200, data: catalog))
    LibraryURLProtocol.register(newURL, .init(status: 200, data: catalog))
    await library.refresh(oldID)
    #expect(library.sources.first(where: { $0.id == oldID })?.catalog != nil)

    #expect(throws: (any Error).self) { try library.updateSource(oldID, url: ResourceLibrary.officialURL.absoluteString) }
    #expect(try library.updateSource(oldID, url: oldURL.absoluteString) == oldID)
    #expect(library.sources.first(where: { $0.id == oldID })?.refreshedAt != nil)
    let newID = try library.updateSource(oldID, url: newURL.absoluteString)
    #expect(newID != oldID)
    #expect(library.sources.dropFirst().map(\.id) == [newID, otherID])
    #expect(library.sources.first(where: { $0.id == newID })?.catalog == nil)
    #expect(library.sources.first(where: { $0.id == newID })?.refreshedAt == nil)
    await library.refresh(newID)
    let restored = ResourceLibrary(directory: directory)
    #expect(restored.sources.first(where: { $0.id == newID })?.catalog != nil)
    #expect(!restored.sources.contains(where: { $0.id == oldID }))
}

@Test @MainActor
func subscriptionNameOverrideSurvivesRefreshAndCanReturnToCatalogName() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ResourceLibrary(directory: directory, session: librarySession())
    let url = URL(string: "https://fixtures.example/rename/catalog.json")!
    let id = try library.addSource(url.absoluteString, name: "  My Library  ")
    LibraryURLProtocol.register(url, .init(status: 200, data: try sourceCatalog(Data())))
    await library.refresh(id)
    #expect(library.sources.first { $0.id == id }?.title == "My Library")
    #expect(try library.updateSource(id, url: url.absoluteString, name: "Renamed") == id)
    let official = try #require(library.sources.first)
    #expect(try library.updateSource(official.id, url: official.url.absoluteString, name: "Built In") == official.id)

    let restored = ResourceLibrary(directory: directory)
    #expect(restored.sources.first?.title == "Built In")
    #expect(restored.sources.first?.isDefault == true)
    #expect(restored.sources.first { $0.id == id }?.title == "Renamed")
    #expect(try restored.updateSource(id, url: url.absoluteString, name: "") == id)
    let source = try #require(restored.sources.first { $0.id == id })
    #expect(source.catalog != nil)
    #expect(source.title == source.catalog?.name.resolve())
}

private func copyResourceFixture(to directory: URL, id: String = "xiaomi-2-pro", release: String = "1.0.0",
                                 vendor: Int = 10007, product: Int = 12984) throws -> URL {
    let folder = directory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: resourceFixture(), to: folder)
    let manifestURL = folder.appending(path: "manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["id"] = id; manifest["release"] = release
    manifest["devices"] = [["vendor": vendor, "product": product]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    return folder
}

@Test @MainActor
func installedSelectionPersistsWithoutConnectionAndUpdatePreservesProfiles() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = directory.appending(path: "configuration.json")
    let input = LibraryInputSource(); input.state = .listening
    let model = RemoteModel(hid: input, storeURL: store, permissions: .init(postEvents: { true }, accessibility: { true }),
                            runAction: { _, _ in })
    try model.installModel(from: resourceFixture())
    let firstDevice = DeviceID(vendor: 10007, product: 12984, name: "Device A")
    input.onDevices([firstDevice]); model.refreshPermissions()
    #expect(model.connected)
    let second = try copyResourceFixture(to: directory, id: "independent-remote", vendor: 5432, product: 1234)
    try model.installModel(from: second)
    model.previewModel("independent-remote")
    #expect(model.remoteDefinition.id == "independent-remote")
    #expect(!model.connected)
    #expect(input.selectedDevice == nil)
    input.onAmbiguousDevices([firstDevice])
    #expect(model.selectedAmbiguousDevices.isEmpty)
    #expect(model.connectionStatus == L10n.tr("未连接"))
    #expect(model.profile?.actions == model.remoteDefinition.manifest.defaults)
    model.setAction(.showDesktop, for: "home")
    #expect(model.saveConfigurationChanges(as: "My setup"))
    let profile = try #require(model.profile)
    #expect(profile.modelID == "independent-remote")
    #expect(profile.actions["home"] == .showDesktop)
    let update = try copyResourceFixture(to: directory, id: "independent-remote", release: "1.1.0", vendor: 5432, product: 1234)
    try model.installModel(from: update)
    #expect(model.profile?.id == profile.id)
    #expect(model.profile?.actions["home"] == .showDesktop)
    let restoredInput = LibraryInputSource()
    let restored = RemoteModel(hid: restoredInput, storeURL: store, runAction: { _, _ in })
    restoredInput.onDevices([firstDevice])
    #expect(restored.remoteDefinition.id == "independent-remote")
    #expect(!restored.connected)
    #expect(restored.profile?.id == profile.id)
    #expect(restored.remoteDefinition.manifest.release == "1.1.0")
    restored.setAction(.volumeUp, for: "home")
    let blocked = try copyResourceFixture(to: directory, id: "independent-remote", release: "1.2.0", vendor: 5432, product: 1234)
    #expect(throws: RemotePackageError.self) { try restored.installModel(from: blocked) }
    #expect(restored.remoteDefinition.manifest.release == "1.1.0")
    #expect(restored.hasConfigurationChanges)
}

@Test @MainActor
func permissionsAreRequestedOnUseAndNeverAtEmptyStartup() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = LibraryInputSource()
    var dispatched: [AgentAction] = []
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            permissions: .init(postEvents: { false }, accessibility: { false }),
                            runAction: { action, _ in dispatched.append(action) })
    #expect(model.requestedPermission == nil)
    try model.installModel(from: resourceFixture())
    model.pressVirtualKey("up")
    #expect(model.requestedPermission == .inputMonitoring)
    model.requestedPermission = nil
    input.state = .listening
    input.onDevices([.init(vendor: 10007, product: 12984, name: "Test remote")])
    model.refreshPermissions()
    model.pressVirtualKey("up")
    #expect(model.requestedPermission == .accessibility)
    #expect(dispatched.isEmpty)
}

@Test @MainActor
func malformedRefreshPreservesValidatedCacheAndRejectsLegacyLocalizedStrings() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try await Task.detached { try libraryArchive(directory) }.value
    let session = librarySession(); defer { session.invalidateAndCancel() }
    let library = ResourceLibrary(directory: directory, session: session)
    let url = URL(string: "https://fixtures.example/\(UUID().uuidString)/catalog.json")!
    let id = try library.addSource(url.absoluteString)
    let original = try sourceCatalog(data)
    LibraryURLProtocol.register(url, .init(status: 200, data: original)); await library.refresh(id)
    var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    json["name"] = "Legacy string not v2"
    LibraryURLProtocol.register(url, .init(status: 200, data: try JSONSerialization.data(withJSONObject: json)))
    await library.refresh(id)
    #expect(library.errors[id] != nil)
    #expect(library.sources.first { $0.id == id }?.catalog?.name.resolve(locale: Locale(identifier: "en")) == "Test source")
}

@Test @MainActor
func directLocalZIPImportUsesTheSameValidatedInstallerAndPersistsOffline() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await Task.detached { try libraryArchive(directory) }.value
    let store = directory.appending(path: "configuration.json")
    let model = RemoteModel(hid: LibraryInputSource(), storeURL: store, runAction: { _, _ in })
    try await model.installResourcePackage(from: directory.appending(path: "fixture.zip"))
    #expect(model.installedModels.count == 1)
    #expect(model.installedOwner(of: "xiaomi-2-pro") == "local")
    let restored = RemoteModel(hid: LibraryInputSource(), storeURL: store, runAction: { _, _ in })
    #expect(restored.remoteDefinition.id == "xiaomi-2-pro")
    #expect(restored.remoteDefinition.logo != nil)
    #expect(restored.remoteDefinition.manifest.localizedName.resolve(locale: Locale(identifier: "zh-Hans")) == "小米蓝牙遥控器 2 Pro")
}

@Test @MainActor
func switchingBackFromOfflinePreviewReattachesThePreviouslySelectedHID() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = LibraryInputSource(); input.state = .listening
    let device = DeviceID(vendor: 10007, product: 12984, name: "Connected A")
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            permissions: .init(postEvents: { true }, accessibility: { true }), runAction: { _, _ in })
    try model.installModel(from: resourceFixture())
    let second = try copyResourceFixture(to: directory, id: "offline-b", vendor: 2222, product: 3333)
    try model.installModel(from: second)
    input.onDevices([device]); model.refreshPermissions()
    model.previewModel("xiaomi-2-pro")
    #expect(input.selectedDevice == device)
    model.previewModel("offline-b")
    #expect(input.selectedDevice == nil)
    model.previewModel("xiaomi-2-pro")
    #expect(input.selectedDevice == device)
    #expect(model.connectedDevice == device)
    #expect(model.canReadKeys)
}

@Test @MainActor
func deniedInputMonitoringRemainsDeniedWhileHardwareIsAmbiguous() throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = LibraryInputSource(); input.state = .ambiguous
    let model = RemoteModel(hid: input, storeURL: directory.appending(path: "configuration.json"),
                            permissions: .init(postEvents: { true }, accessibility: { true }, listenEvents: { false }),
                            runAction: { _, _ in })
    try model.installModel(from: resourceFixture())
    model.refreshPermissions()
    #expect(model.monitorState == .ambiguous)
    #expect(!model.canListen)
    #expect(PermissionKind.inputMonitoring.status(in: model) == .notAllowed)
    model.pressVirtualKey("up")
    #expect(model.requestedPermission == .inputMonitoring)
}

@Test @MainActor
func aggregateCatalogLimitKeepsLastReadableCacheInsteadOfBrickingSubscriptions() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = librarySession(); defer { session.invalidateAndCancel() }
    let library = ResourceLibrary(directory: directory, session: session)
    let large = String(repeating: "A", count: 3800)
    let models: [[String: Any]] = (0..<220).map { index in
        ["id": "model-\(index)", "release": "1.0.0", "name": ["en": large], "summary": ["en": large],
         "package": "remote.zip", "packageSHA256": String(repeating: "0", count: 64)]
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "formatVersion": 2, "id": "large-source", "name": ["en": "Large source"], "models": models
    ])
    #expect(data.count < 2 * 1024 * 1024)
    var rejected = 0
    for _ in 0..<5 {
        let url = URL(string: "https://fixtures.example/\(UUID().uuidString)/catalog.json")!
        let id = try library.addSource(url.absoluteString)
        LibraryURLProtocol.register(url, .init(status: 200, data: data))
        await library.refresh(id)
        if library.errors[id] != nil { rejected += 1 }
    }
    #expect(rejected > 0)
    #expect(library.sources.filter { $0.catalog != nil }.count > 0)
    let saved = try Data(contentsOf: directory.appending(path: "subscriptions.json"))
    #expect(saved.count <= 8 * 1024 * 1024)
    let restored = ResourceLibrary(directory: directory, session: session)
    #expect(restored.storageError == nil)
    #expect(restored.sources.count == library.sources.count)
    #expect(restored.sources.filter { $0.catalog != nil }.count == library.sources.filter { $0.catalog != nil }.count)
    #expect((try? restored.addSource("https://fixtures.example/after-reload/catalog.json")) != nil)
}

@Test @MainActor
func installedPackageArtworkAndLogoRenderAfterTemporaryInstallerFilesAreRemoved() async throws {
    let directory = try temporaryLibraryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await Task.detached { try libraryArchive(directory) }.value
    let model = RemoteModel(hid: LibraryInputSource(), storeURL: directory.appending(path: "configuration.json"), runAction: { _, _ in })
    try await model.installResourcePackage(from: directory.appending(path: "fixture.zip"))
    let definition = model.remoteDefinition
    let body = RemoteArtwork(definition: definition, highlight: { _ in .clear }, help: { $0.name }, activate: { _ in })
        .frame(width: 200, height: 600)
    let cg = try #require(ImageRenderer(content: body).cgImage)
    let image = NSBitmapImageRep(cgImage: cg)
    let center = try #require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2))
    #expect(center.alphaComponent > 0.9)
    let logo = try #require(definition.logo)
    let logoCG = try #require(ImageRenderer(content: Image(nsImage: logo).resizable().frame(width: 40, height: 40)).cgImage)
    let logoBitmap = NSBitmapImageRep(cgImage: logoCG)
    let logoCenter = try #require(logoBitmap.colorAt(x: 20, y: 20))
    #expect(logoCenter.alphaComponent > 0.9)
}
