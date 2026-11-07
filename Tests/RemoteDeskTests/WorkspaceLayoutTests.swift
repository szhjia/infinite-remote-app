import Foundation
import Testing
@testable import RemoteDesk

@Test
func layoutFileCanChangeTheMinimumAndStartingWidth() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: WorkspaceLayout.filename)

    let defaults = WorkspaceLayout.load(from: directory)
    #expect(defaults.initialSize.width == 1311)
    #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: Data(contentsOf: file)) == defaults)

    let edited = Data("""
        {"sidebarWidth": 210, "deviceContentWidth": 450, "appRailWidth": 96, "keyMappingWidth": 620}
        """.utf8)
    try edited.write(to: file)
    let layout = WorkspaceLayout.load(from: directory)
    #expect(layout.deviceContentWidth == 450)
    #expect(layout.minimumSize.width == 1379)
    #expect(layout.initialSize.width == layout.minimumSize.width)
    #expect(try Data(contentsOf: file) == edited)
}

@Test
func invalidLayoutUsesDefaultsAndLeavesTheFileAvailableToFix() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: WorkspaceLayout.filename)
    let invalid = Data("""
        {"sidebarWidth": 200, "deviceContentWidth": -420, "appRailWidth": 88, "keyMappingWidth": 600}
        """.utf8)
    try invalid.write(to: file)

    #expect(WorkspaceLayout.load(from: directory) == .defaults)
    #expect(try Data(contentsOf: file) == invalid)
}
