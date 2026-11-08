import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init?() {
        // SwiftPM executables and test hosts have no release update configuration.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return nil }

        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var appUpdater: AppUpdater

    var body: some View {
        Button(L10n.tr("检查更新…"), action: appUpdater.checkForUpdates)
            .disabled(!appUpdater.canCheckForUpdates)
    }
}
