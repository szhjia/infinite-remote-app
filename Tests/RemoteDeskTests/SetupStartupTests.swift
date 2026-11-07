import Foundation
import Testing
@testable import RemoteDesk

@Test
func firstRunStaysInSetupUntilFinishedEvenAfterInstallingAModel() throws {
    let suite = "RemoteDesk.setup-startup-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(SetupStartup.requiresGuide(in: defaults, hasModel: false))
    SetupStartup.begin(in: defaults)
    let resumed = try #require(UserDefaults(suiteName: suite))
    #expect(SetupStartup.requiresGuide(in: resumed, hasModel: true))
    SetupStartup.finish(in: resumed)
    #expect(!SetupStartup.requiresGuide(in: defaults, hasModel: false))
    #expect(!SetupStartup.requiresGuide(in: defaults, hasModel: true))
}

@Test
func upgradesKeepPriorModelAndSkipDecisions() throws {
    let suite = "RemoteDesk.setup-upgrade-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!SetupStartup.requiresGuide(in: defaults, hasModel: true))
    defaults.set(true, forKey: "RemoteDesk.setupGuideHidden")
    #expect(!SetupStartup.requiresGuide(in: defaults, hasModel: false))
}

@Test
func deferredSetupRestoresTheLastStepWithoutMarkingItFinished() throws {
    let suite = "RemoteDesk.setup-deferred-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    SetupStartup.begin(in: defaults)
    #expect(SetupStartup.stage(in: defaults, hasModel: false) == .welcome)
    SetupStartup.save(.permissions, in: defaults)

    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(SetupStartup.requiresGuide(in: reopened, hasModel: true))
    #expect(SetupStartup.stage(in: reopened, hasModel: true) == .permissions)

    SetupStartup.finish(in: reopened)
    #expect(!SetupStartup.requiresGuide(in: reopened, hasModel: true))
    #expect(SetupStartup.stage(in: reopened, hasModel: true) == .welcome)
}

@Test
func unfinishedLegacyGuideWithInstalledRemoteResumesAtConnection() throws {
    let suite = "RemoteDesk.setup-migration-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    SetupStartup.begin(in: defaults)
    #expect(SetupStartup.stage(in: defaults, hasModel: true) == .remote)
}

@Test
func driverStepResumesAfterRestartWithoutShiftingSavedLegacySteps() throws {
    let suite = "RemoteDesk.setup-driver-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    SetupStartup.begin(in: defaults)
    #expect(SetupStage.welcome.adjacent(1) == .voiceDriver)
    #expect(SetupStage.voiceDriver.position == 1)
    #expect(SetupStage.voiceDriver.adjacent(1) == .remote)
    #expect(SetupStage.remote.adjacent(-1) == .voiceDriver)

    SetupStartup.save(.voiceDriver, in: defaults)
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(SetupStartup.requiresGuide(in: reopened, hasModel: false))
    #expect(SetupStartup.stage(in: reopened, hasModel: false) == .voiceDriver)

    reopened.set(1, forKey: "RemoteDesk.setupStage")
    #expect(SetupStartup.stage(in: reopened, hasModel: true) == .remote)
    reopened.set(2, forKey: "RemoteDesk.setupStage")
    #expect(SetupStartup.stage(in: reopened, hasModel: true) == .permissions)
}
