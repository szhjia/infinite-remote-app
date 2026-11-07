import Foundation
import RemoteCore

struct ProfileArchive: Codable {
    let version: Int
    let name: String
    let modelID: String?
    let target: AppTarget?
    private(set) var actions: [String: AgentAction]

    // Version 1 archives predate explicit model associations.
    var associatedModelID: String { modelID ?? "xiaomi-2-pro" }

    init(_ profile: AgentProfile) {
        version = profile.modelID == nil ? 1 : (profile.target == nil ? 2 : 3)
        modelID = profile.modelID
        target = version == 3 ? profile.target.map { AppTarget(bundleID: $0.bundleID) } : nil
        name = profile.name
        actions = profile.actions.filter { !$0.value.isRemovedVoiceBinding }
    }
    static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 64 * 1024
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var archive = try JSONDecoder().decode(Self.self, from: data)
        guard (archive.version == 1 && archive.modelID == nil && archive.target == nil)
                || (archive.version == 2 && archive.modelID != nil && archive.target == nil)
                || (archive.version == 3 && archive.modelID != nil
                    && archive.target?.bundleID.isEmpty == false && archive.target?.path == nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        archive.actions = archive.actions.filter { !$0.value.isRemovedVoiceBinding }
        return archive
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
