import Foundation

struct WorkspaceLayout: Codable, Equatable {
    static let defaults = Self(sidebarWidth: 200, deviceContentWidth: 420, appRailWidth: 88, keyMappingWidth: 600)
    static let dividerWidth: CGFloat = 1
    static let filename = "workspace-layout.json"

    let sidebarWidth: CGFloat
    let deviceContentWidth: CGFloat
    let appRailWidth: CGFloat
    let keyMappingWidth: CGFloat

    var appMappingWidth: CGFloat { appRailWidth + Self.dividerWidth + keyMappingWidth }

    var minimumWidth: CGFloat {
        sidebarWidth + deviceContentWidth + appMappingWidth + 2 * Self.dividerWidth
    }

    var initialSize: CGSize { CGSize(width: minimumWidth, height: 720) }
    var minimumSize: CGSize { CGSize(width: minimumWidth, height: 520) }

    static func load(from directory: URL) -> Self {
        let file = directory.appending(path: filename)
        do {
            let data = try Data(contentsOf: file)
            let layout = try JSONDecoder().decode(Self.self, from: data)
            let widths = [layout.sidebarWidth, layout.deviceContentWidth, layout.appRailWidth, layout.keyMappingWidth]
            return widths.allSatisfy { (1...4096).contains($0) } ? layout : defaults
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(defaults) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .withoutOverwriting)
            }
            return defaults
        } catch {
            return defaults
        }
    }
}
