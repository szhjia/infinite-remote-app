import Foundation
import RemoteCore

struct ProfileArchive: Codable {
    let version: Int
    let name: String
    let actions: [String: AgentAction]

    init(_ profile: AgentProfile) {
        version = 1
        name = profile.name
        actions = profile.actions
    }
    static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 64 * 1024
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        let slots = Set(RemoteKey.xiaomi.map(\.id) + ["power-long"])
        guard archive.version == 1, archive.actions.keys.allSatisfy(slots.contains) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
