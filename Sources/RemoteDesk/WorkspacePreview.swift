#if DEBUG
import RemoteCore
import SwiftUI

#Preview("首次使用 / First Run") {
    WorkspacePreview(installModel: false)
}

#Preview("遥控器工作台 / Remote Workspace") {
    WorkspacePreview(installModel: true)
}

private struct WorkspacePreview: View {
    @State private var page: Workspace.Page = .remote
    @State private var fixture: WorkspacePreviewFixture
    let installModel: Bool

    init(installModel: Bool) {
        self.installModel = installModel
        _fixture = State(initialValue: WorkspacePreviewFixture(installModel: installModel))
    }

    var body: some View {
        if let error = fixture.error {
            ContentUnavailableView("Preview fixture unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if installModel {
            Workspace(model: fixture.model, library: fixture.library, page: $page,
                      showDiagnostics: {}, showSettings: { _ in })
                .defaultAppStorage(fixture.defaults)
                .frame(width: Workspace.windowSize.width, height: Workspace.windowSize.height)
        } else {
            SetupGuide(model: fixture.model, library: fixture.library, stage: .welcome,
                       saveStage: { _ in }, deferSetup: {}, finish: {})
                .defaultAppStorage(fixture.defaults)
                .frame(width: SetupGuide.windowSize.width, height: SetupGuide.windowSize.height)
        }
    }
}

@MainActor
private final class WorkspacePreviewFixture {
    let model: RemoteModel
    let library: ResourceLibrary
    let defaults: UserDefaults
    private let directory: URL
    private let defaultsName: String
    private(set) var error: String?

    init(installModel: Bool) {
        let token = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appending(path: "RemoteDesk-preview-" + token)
        defaultsName = "RemoteDesk.preview." + token
        defaults = UserDefaults(suiteName: defaultsName)!
        model = RemoteModel(hid: PreviewInput(), storeURL: directory.appending(path: "configuration.json"),
                            permissions: .init(postEvents: { false }, accessibility: { false },
                                               listenEvents: { installModel }), runAction: { _, _ in })
        library = ResourceLibrary(directory: model.libraryDirectory)
        guard installModel else { return }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/RemoteDeskTests/Fixtures/Packages/xiaomi-2-pro")
        do {
            try model.installModel(from: fixture)
            model.refreshPermissions()
        } catch {
            self.error = error.localizedDescription
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
    }
}

@MainActor
private final class PreviewInput: RemoteInputSource {
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onMonitorState: (InputMonitorState) -> Void = { _ in }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void = { _, _ in }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void = { _ in }
    var selectedDevice: DeviceID?

    func refresh() -> InputMonitorState {
        onDevices([DeviceID(vendor: 0x2717, product: 0x32B8, name: "Xiaomi Remote")])
        return selectedDevice == nil ? .idle : .listening
    }
}
#endif
