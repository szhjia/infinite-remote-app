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

/// Tests that exercise the installer use a real installation transaction.
@MainActor
func fixtureCatalog(directory: URL) -> RemoteCatalog {
    var catalog = RemoteCatalog(directory: directory)
    if !catalog.models.contains(where: { $0.id == RemoteDefinition.xiaomiID }) {
        do { _ = try catalog.install(legacyModelFixtureURL) }
        catch { preconditionFailure("Cannot install legacy model test fixture: \(error)") }
    }
    return catalog
}

/// Routing tests start with an existing model. RemoteModel still loads and validates the copy.
@MainActor
func seedInstalledLegacyModel(in directory: URL) {
    let files = FileManager.default
    let model = directory.appending(path: RemoteDefinition.xiaomiID, directoryHint: .isDirectory)
    guard !files.fileExists(atPath: model.path) else { return }
    do {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.copyItem(at: legacyModelFixtureURL, to: model)
    } catch {
        preconditionFailure("Cannot seed installed model test fixture: \(error)")
    }
}

@MainActor
func fixtureRemoteModel(hid: any RemoteInputSource, storeURL: URL,
                        dictation: DictationController = DictationController(),
                        permissions: PermissionAccess = .init(postEvents: { true }, accessibility: { true }),
                        powerHoldDelay: Duration = .milliseconds(600),
                        doubleClickDelay: Duration = .milliseconds(300),
                        gestureNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                        runAction: @escaping @MainActor (AgentAction, AppTarget?) async throws -> Void) -> RemoteModel {
    seedInstalledLegacyModel(in: storeURL.deletingLastPathComponent().appending(path: "RemoteModels"))
    let model = RemoteModel(hid: hid, storeURL: storeURL, dictation: dictation, permissions: permissions,
                            powerHoldDelay: powerHoldDelay, doubleClickDelay: doubleClickDelay, gestureNow: gestureNow,
                            foreground: { .init(bundleID: AppTarget.chatGPT.bundleID, pid: 123) }, runAction: runAction)
    model.selectEditingApp(.chatGPT)
    return model
}

/// v9 makes the formerly implicit legacy profile association explicit.
@MainActor
func legacyModelProfile(_ profile: AgentProfile) -> AgentProfile {
    var profile = profile
    profile.modelID = RemoteDefinition.xiaomiID
    if profile.id == AgentProfile.defaults.id {
        profile.name = L10n.tr("默认配置")
        profile.actions["home"] = .openFinder
        profile.actions["voice"] = .chatGPTDraft
    }
    return profile
}
