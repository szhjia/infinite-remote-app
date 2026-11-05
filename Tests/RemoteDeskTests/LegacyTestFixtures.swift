import Foundation
import RemoteCore
@testable import RemoteDesk

/// Legacy bytes belong to the test target; the shipping app starts without models.
var legacyModelFixtureURL: URL {
    Bundle.module.url(forResource: "xiaomi-2-pro", withExtension: nil,
                      subdirectory: "Fixtures/LegacyModels")!
}

extension RemoteCatalog {
    /// A reader fixture only. Accessing it never installs a production model.
    @MainActor var builtIn: RemoteDefinition {
        do { return try RemoteDefinition.read(legacyModelFixtureURL) }
        catch { preconditionFailure("Invalid legacy model test fixture: \(error)") }
    }
}

/// Tests that require an installed Xiaomi explicitly seed their isolated catalog.
@MainActor
func fixtureCatalog(directory: URL) -> RemoteCatalog {
    var catalog = RemoteCatalog(directory: directory)
    if !catalog.models.contains(where: { $0.id == RemoteDefinition.xiaomiID }) {
        do { _ = try catalog.install(legacyModelFixtureURL) }
        catch { preconditionFailure("Cannot install legacy model test fixture: \(error)") }
    }
    return catalog
}

@MainActor
func fixtureRemoteModel(hid: any RemoteInputSource, storeURL: URL,
                        dictation: DictationController = DictationController(),
                        permissions: PermissionAccess = .init(postEvents: { true }, accessibility: { true }),
                        powerHoldDelay: Duration = .milliseconds(600),
                        doubleClickDelay: Duration = .milliseconds(300),
                        runAction: @escaping @MainActor (AgentAction, AppTarget?) async throws -> Void) -> RemoteModel {
    _ = fixtureCatalog(directory: storeURL.deletingLastPathComponent().appending(path: "RemoteModels"))
    return RemoteModel(hid: hid, storeURL: storeURL, dictation: dictation, permissions: permissions,
                       powerHoldDelay: powerHoldDelay, doubleClickDelay: doubleClickDelay, runAction: runAction)
}

/// v9 makes the formerly implicit legacy profile association explicit.
@MainActor
func legacyModelProfile(_ profile: AgentProfile) -> AgentProfile {
    var profile = profile
    profile.modelID = RemoteDefinition.xiaomiID
    if profile.id == AgentProfile.defaults.id { profile.name = L10n.tr("默认配置") }
    return profile
}
