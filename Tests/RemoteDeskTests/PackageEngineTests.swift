import AppKit
import Foundation
import RemoteCore
import Testing
@testable import RemoteDesk

private struct EngineFixture {
    let directory: URL
    let package: URL

    init(version: Int = 2, id: String = "example-remote", release: String = "1.0.0") throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "package-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        package = directory.appending(path: "source")
        let legacy = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/LegacyModels/xiaomi-2-pro"))
        try FileManager.default.copyItem(at: legacy, to: package)
        try mutate("manifest.json") { object in
            object["version"] = version
            object["id"] = id
            if version == 2 {
                object["release"] = release
                object["name"] = ["en": "Example Remote", "zh": "示例遥控器"]
                object["summary"] = ["en": "A package fixture."]
                object["brand"] = ["id": "example", "name": ["en": "Example"]]
                object["capabilities"] = (object["capabilities"] as? [[String: Any]] ?? []).map { capability in
                    var value = capability
                    for field in ["name", "description", "status"] {
                        if let text = value[field] as? String { value[field] = ["en": text] }
                    }
                    return value
                }
            }
        }
        if version == 2 {
            try mutate("layout.json") { object in
                object["keys"] = (object["keys"] as? [[String: Any]] ?? []).map { key in
                    var value = key
                    if let name = value["name"] as? String { value["name"] = ["en": name] }
                    return value
                }
            }
        }
    }

    func mutate(_ name: String, _ change: (inout [String: Any]) throws -> Void) throws {
        let file = package.appending(path: name)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        try change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Test
func emptyCatalogHasNoRealModelAndEmptyPresentationHasNoActions() {
    let catalog = RemoteCatalog(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    #expect(catalog.models.isEmpty)
    #expect(catalog.loadIssues.isEmpty)
    #expect(catalog.model(for: DeviceID(vendor: 0x2717, product: 0x32b8, name: "Remote")) == nil)
    #expect(RemoteDefinition.empty.id.isEmpty)
    #expect(RemoteDefinition.empty.layout.keys.isEmpty)
    #expect(RemoteDefinition.empty.actionSlots.isEmpty)
}

@Test
func packageLocalizationUsesRequestedLanguageThenEnglish() throws {
    let text = try JSONDecoder().decode(LocalizedText.self, from: Data(#"{"en":"Remote","zh":"遥控器"}"#.utf8))
    #expect(text.isValid)
    #expect(text.resolve(locale: Locale(identifier: "zh-Hans-CN")) == "遥控器")
    #expect(text.resolve(locale: Locale(identifier: "fr-FR")) == "Remote")
    #expect(LocalizedText("Legacy").resolve(locale: Locale(identifier: "zh")) == "Legacy")
    #expect(!LocalizedText(translations: ["zh": "遥控器"]).isValid)
}

@Test
func packageReleasesCompareNumericallyAndRejectAmbiguousVersions() throws {
    #expect(try PackageVersion("1.10.0") > PackageVersion("1.9.99"))
    #expect(try PackageVersion("2.0.0") > PackageVersion("1.4294967295.0"))
    for invalid in ["1.0", "1.0.0-beta", "01.0.0", "-1.0.0", "1.0.0.0", "4294967296.0.0"] {
        #expect(throws: RemotePackageError.self) { try PackageVersion(invalid) }
    }
}

@Test
func v2DefaultsAreGenericAndV1XiaomiCompatibilityStaysAtReadBoundary() throws {
    let generic = try EngineFixture()
    defer { generic.cleanup() }
    let definition = try RemoteDefinition.read(generic.package)
    #expect(definition.manifest.defaults.isEmpty)
    #expect(definition.manifest.behavior == .empty)
    #expect(definition.manifest.target == nil)
    #expect(definition.manifest.release == "1.0.0")
    let legacy = try EngineFixture(version: 1, id: RemoteDefinition.xiaomiID)
    defer { legacy.cleanup() }
    let adapted = try RemoteDefinition.read(legacy.package)
    #expect(adapted.manifest.defaults == AgentProfile.defaults.actions)
    #expect(adapted.manifest.target == AgentProfile.defaults.target)
    #expect(adapted.manifest.behavior.coalescedKeys == ["home", "tv", "menu"])
    #expect(adapted.manifest.behavior.consumesContextMenu)
    let other = try EngineFixture(version: 1)
    defer { other.cleanup() }
    #expect(try RemoteDefinition.read(other.package).manifest.defaults.isEmpty)
}

@Test
func legacyV1PackagePreservesReadableHistoricalActionDescriptors() throws {
    let fixture = try EngineFixture(version: 1)
    defer { fixture.cleanup() }
    try fixture.mutate("manifest.json") {
        $0["defaults"] = [
            "home": ["openLink": ["_0": "https://example.com/help"]],
            "menu": ["chatBar": [:]],
            "tv": ["nextAgent": [:]]
        ]
    }
    let defaults = try RemoteDefinition.read(fixture.package).manifest.defaults
    #expect(defaults["home"] == .openLink("https://example.com/help"))
    #expect(defaults["menu"] == .chatBar)
    #expect(defaults["tv"] == .nextAgent)
}

@Test
func partialBehaviorDefaultsMissingFieldsAndValidatesReferences() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    try fixture.mutate("manifest.json") { $0["behavior"] = ["deferredKeys": ["power"]] }
    let behavior = try RemoteDefinition.read(fixture.package).manifest.behavior
    #expect(behavior.deferredKeys == ["power"])
    #expect(behavior.coalescedKeys.isEmpty)
    #expect(behavior.nativeDictationKeys.isEmpty)
    #expect(!behavior.consumesContextMenu)
    try fixture.mutate("manifest.json") { $0["behavior"] = ["nativeDictationKeys": ["unknown"]] }
    #expect(throws: RemotePackageError.self) { try RemoteDefinition.read(fixture.package) }
}

@Test
func v2RejectsStringLocalizationUnsafeDefaultsAndExecutableTargets() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    let original = try Data(contentsOf: fixture.package.appending(path: "manifest.json"))
    let invalidCases: [[String: Any]] = [
        ["name": "A legacy name"],
        ["summary": ["zh": "没有英文"]],
        ["defaults": ["unknown": ["openApp": [:]]]],
        ["defaults": ["voice": ["openLink": ["_0": "file:///bin/sh"]]]],
        ["defaults": ["home": ["openLink": ["_0": "https://example.com/help"]]]],
        ["defaults": ["home": ["chatBar": [:]]]],
        ["defaults": ["home": ["nextAgent": [:]]]],
        ["defaults": ["voice": ["systemDictation": [:]]]],
        ["defaults": ["power-long": ["dictation": [:]]]],
        ["defaults": ["power": ["dictation": [:]], "power-long": ["openApp": [:]]]],
        ["target": ["bundleID": "com.example.app", "path": "/tmp/executable"]],
        ["behavior": ["coalescedKeys": ["home", "home"]]],
        ["version": 99]
    ]
    for changes in invalidCases {
        try original.write(to: fixture.package.appending(path: "manifest.json"))
        try fixture.mutate("manifest.json") { object in changes.forEach { object[$0.key] = $0.value } }
        #expect(throws: RemotePackageError.self) { try RemoteDefinition.read(fixture.package) }
    }
}

@Test
func installationPersistsOwnershipAndOnlyAcceptsNewerReleaseFromSameSource() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    let installed = fixture.directory.appending(path: "installed")
    var catalog = RemoteCatalog(directory: installed)
    try Data(#"{"modelID":"example-remote","sourceID":"forged","release":"1.0.0"}"#.utf8)
        .write(to: fixture.package.appending(path: ".installation.json"))
    _ = try catalog.install(fixture.package, sourceID: "official")
    #expect(catalog.owner(of: "example-remote") == "official")
    #expect(throws: RemotePackageError.self) { try catalog.install(fixture.package, sourceID: "official") }
    try fixture.mutate("manifest.json") { $0["release"] = "1.1.0" }
    #expect(throws: RemotePackageError.self) { try catalog.install(fixture.package, sourceID: "another-source") }
    _ = try catalog.install(fixture.package, sourceID: "official")
    let reloaded = RemoteCatalog(directory: installed)
    #expect(reloaded.loadIssues.isEmpty)
    #expect(reloaded.owner(of: "example-remote") == "official")
    #expect(reloaded.models.first?.manifest.release == "1.1.0")
    #expect(FileManager.default.fileExists(atPath: try #require(reloaded.models.first).front.path))
}

@Test
func failedUpdateLeavesPriorInstallationAndDeviceConflictsAreRejected() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    let installed = fixture.directory.appending(path: "installed")
    var catalog = RemoteCatalog(directory: installed)
    _ = try catalog.install(fixture.package)
    try fixture.mutate("manifest.json") { $0["release"] = "2.0.0"; $0["front"] = "missing.png" }
    #expect(throws: (any Error).self) { try catalog.install(fixture.package) }
    #expect(catalog.models.first?.manifest.release == "1.0.0")
    #expect(RemoteCatalog(directory: installed).models.first?.manifest.release == "1.0.0")
    try fixture.mutate("manifest.json") { $0["id"] = "another-model"; $0["front"] = "front.png" }
    #expect(throws: RemotePackageError.self) { try catalog.install(fixture.package) }
    #expect(catalog.models.count == 1)
}

@Test
func packageUpdatesPreserveEveryPreviouslyExposedActionSlot() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    var catalog = RemoteCatalog(directory: fixture.directory.appending(path: "installed"))
    _ = try catalog.install(fixture.package)
    try fixture.mutate("manifest.json") { $0["release"] = "2.0.0" }
    try fixture.mutate("layout.json") { object in
        object["keys"] = (object["keys"] as? [[String: Any]] ?? []).map { key in
            var key = key
            if key["id"] as? String == "power" { key["longPress"] = false }
            return key
        }
    }
    #expect(throws: RemotePackageError.self) { try catalog.install(fixture.package) }
    #expect(catalog.models.first?.manifest.release == "1.0.0")
}

private struct EngineZipEntry {
    let path: String
    var contents: Data = Data("hello".utf8)
    var method: UInt16 = 0
    var flags: UInt16 = 0
    var external: UInt32 = 0x81a40000
    var expanded: Int? = nil
    var checksum: UInt32? = nil
    var localPath: String? = nil
}

private func engineCRC(_ bytes: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
    }
    return crc ^ UInt32.max
}

private func engineZIP(_ entries: [EngineZipEntry]) -> Data {
    func u16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    func u32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    var data = Data(), central = Data()
    for entry in entries {
        let offset = UInt32(data.count)
        let name = Data(entry.path.utf8), localName = Data((entry.localPath ?? entry.path).utf8)
        let size = UInt32(entry.expanded ?? entry.contents.count)
        let crc = entry.checksum ?? engineCRC(entry.contents)
        data += u32(0x04034b50) + u16(20) + u16(entry.flags) + u16(entry.method) + u16(0) + u16(0)
        data += u32(crc) + u32(UInt32(entry.contents.count)) + u32(size) + u16(UInt16(localName.count)) + u16(0)
        data += localName + entry.contents
        central += u32(0x02014b50) + u16(0x0314) + u16(20) + u16(entry.flags) + u16(entry.method) + u16(0) + u16(0)
        central += u32(crc) + u32(UInt32(entry.contents.count)) + u32(size) + u16(UInt16(name.count)) + u16(0) + u16(0)
        central += u16(0) + u16(0) + u32(entry.external) + u32(offset) + name
    }
    let start = data.count
    data += central
    data += u32(0x06054b50) + u16(0) + u16(0) + u16(UInt16(entries.count)) + u16(UInt16(entries.count))
    data += u32(UInt32(central.count)) + u32(UInt32(start)) + u16(0)
    return data
}

@Test
func zipStoredAndDeflatedEntriesRoundTripWithBoundedIntegrityChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Raw RFC1951 DEFLATE of "hello".
    let compressed = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
    let entries = [EngineZipEntry(path: "model/stored.txt"),
                   EngineZipEntry(path: "model/deflated.txt", contents: compressed, method: 8,
                                  expanded: 5, checksum: engineCRC(Data("hello".utf8)))]
    let archive = directory.appending(path: "valid.zip")
    try engineZIP(entries).write(to: archive)
    let extracted = try PackageArchive.extract(archive, to: directory.appending(path: "extracted"))
    #expect(try Data(contentsOf: extracted.appending(path: "stored.txt")) == Data("hello".utf8))
    #expect(try Data(contentsOf: extracted.appending(path: "deflated.txt")) == Data("hello".utf8))
}

@Test
func zipRootDirectoryEntriesAndSymlinkedTempParentsKeepCorrectRelativePaths() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appending(path: UUID().uuidString)
    let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
    let alias = directory.appending(path: "parent-link", directoryHint: .isDirectory)
    try files.createDirectory(at: canonical, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    try files.createSymbolicLink(at: alias, withDestinationURL: canonical)
    let archive = canonical.appending(path: "package.zip")
    try engineZIP([
        EngineZipEntry(path: "model/", contents: Data(), external: 0x41ed0010),
        EngineZipEntry(path: "model/file.txt")
    ]).write(to: archive)
    let extracted = try PackageArchive.extract(archive, to: alias.appending(path: "output", directoryHint: .isDirectory))
    #expect(extracted.lastPathComponent == "model")
    #expect(try Data(contentsOf: extracted.appending(path: "file.txt")) == Data("hello".utf8))
    let canonicalOutput = canonical.appending(path: "output/model/file.txt")
    #expect(files.fileExists(atPath: canonicalOutput.path))
}

@Test
func zipRejectsTraversalDuplicateNamesLinksEncryptionHeaderMismatchAndBombs() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let malformed: [[EngineZipEntry]] = [
        [.init(path: "../outside")], [.init(path: "/model/file")], [.init(path: "model/../file")],
        [.init(path: "model/file"), .init(path: "other/file")],
        [.init(path: "model/file"), .init(path: "model/file")],
        [.init(path: "model/FILE"), .init(path: "model/file")],
        [.init(path: "model/link", external: 0xa1ff0000)],
        [.init(path: "model/file", flags: 1)], [.init(path: "model/file", localPath: "model/other")],
        [.init(path: "model/file", expanded: 64 * 1024 * 1024)],
        [.init(path: "model/file", checksum: 123)],
        [.init(path: "model/file", contents: Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]), method: 8,
               expanded: 1, checksum: 1)]
    ]
    for (index, entries) in malformed.enumerated() {
        let archive = directory.appending(path: "bad-\(index).zip")
        try engineZIP(entries).write(to: archive)
        #expect(throws: RemotePackageError.self) {
            try PackageArchive.extract(archive, to: directory.appending(path: "out-\(index)"))
        }
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "outside").path))
}

@Test
func validZIPInstallsOfflineAndInvalidStoredFoldersReportIssues() throws {
    let fixture = try EngineFixture()
    defer { fixture.cleanup() }
    let entries = try FileManager.default.contentsOfDirectory(at: fixture.package, includingPropertiesForKeys: nil)
        .map { EngineZipEntry(path: "example-remote/" + $0.lastPathComponent, contents: try Data(contentsOf: $0)) }
    let archive = fixture.directory.appending(path: "package.zip")
    try engineZIP(entries).write(to: archive)
    let installed = fixture.directory.appending(path: "installed")
    var catalog = RemoteCatalog(directory: installed)
    let result = try catalog.install(archive)
    #expect(result.id == "example-remote")
    #expect(catalog.owner(of: result.id) == "local")
    try FileManager.default.createDirectory(at: installed.appending(path: "broken"), withIntermediateDirectories: false)
    let reloaded = RemoteCatalog(directory: installed)
    #expect(reloaded.models.count == 1)
    #expect(reloaded.loadIssues.count == 1)
}
