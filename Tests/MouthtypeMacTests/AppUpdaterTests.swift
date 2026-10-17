import AppKit
import Foundation
import Observation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct AppUpdaterTests {
    @Observable final class Activity { var value = UpdateActivity.idle }
    private final class Driver: UpdateDriving {
        weak var delegate: (any UpdateDriverDelegate)?
        var onChange: (() -> Void)?
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = false
        var starts = 0
        var checks = 0
        var startError: Error?
        func start() throws { starts += 1; if let startError { throw startError } }
        func checkForUpdates() { checks += 1 }
    }

    @Test func normalConfiguredAppLaunchIsTheOnlyEligibleStartup() {
        let app = URL(fileURLWithPath: "/Applications/Mouthtype.app")
        let info: [String: Any] = ["SUFeedURL": "https://mouthtype.app/updates/appcast.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
        #expect(UpdateLaunchPolicy.allows(arguments: ["Mouthtype"], bundleURL: app, info: info))
        for argument in ["--pill-demo", "--capture-selftest", "--tap-cycle-selftest", "--recovery-selftest", "--pipeline-selftest", "--probe-input"] {
            #expect(!UpdateLaunchPolicy.allows(arguments: ["Mouthtype", argument], bundleURL: app, info: info))
        }
        #expect(!UpdateLaunchPolicy.allows(arguments: ["Mouthtype"], bundleURL: URL(fileURLWithPath: "/tmp/Mouthtype"), info: info))
        #expect(!UpdateLaunchPolicy.allows(arguments: ["Mouthtype"], bundleURL: app, info: [:]))
        #expect(!UpdateLaunchPolicy.allows(arguments: ["Mouthtype"], bundleURL: app, info: ["SUFeedURL": "http://mouthtype.app/updates/appcast.xml", "SUPublicEDKey": "invalid"]))
    }

    @Test func startupAndChecksWaitForEveryKindOfDictationWork() {
        let activity = Activity(), driver = Driver()
        activity.value = .recording
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        #expect(driver.starts == 0 && !updater.canCheckForUpdates)
        for work in [UpdateActivity.recording, .processing, .recovering, .fileTranscription] {
            activity.value = work
            updater.refreshActivity()
            updater.checkForUpdates()
            #expect(driver.starts == 0 && driver.checks == 0)
        }
        activity.value = .idle
        updater.refreshActivity()
        #expect(driver.starts == 1 && updater.canCheckForUpdates)
        updater.checkForUpdates()
        #expect(driver.checks == 1)
        driver.canCheckForUpdates = false
        driver.onChange?()
        #expect(!updater.canCheckForUpdates)
    }

    @Test func scheduledOfferNeverPresentsDuringARecordingAndWaitsForExplicitIdleReview() {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        updater.checkForUpdates()
        activity.value = .recording
        #expect(throws: NSError.self) { try updater.mayCheckForUpdates() }
        updater.updateAvailable()
        updater.checkForUpdates()
        #expect(updater.hasUpdate && driver.checks == 1)
        activity.value = .idle
        updater.refreshActivity()
        #expect(updater.canCheckForUpdates && driver.checks == 1)
        updater.checkForUpdates()
        #expect(driver.checks == 2 && !updater.hasUpdate)
    }

    @Test func failedStartupCanBeRetriedAndPreferencesUseTheDriver() {
        let driver = Driver()
        driver.startError = NSError(domain: "UpdaterTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updater could not start."])
        let updater = AppUpdater(driver: driver, activity: { .idle })
        updater.start()
        #expect(updater.errorMessage == "Updater could not start.")
        #expect(updater.canCheckForUpdates)
        driver.startError = nil
        updater.checkForUpdates()
        #expect(driver.starts == 2 && driver.checks == 1 && updater.errorMessage == nil)
        updater.setAutomaticChecks(true)
        #expect(driver.automaticallyChecksForUpdates && updater.automaticallyChecksForUpdates)
        updater.setAutomaticChecks(false)
        #expect(!driver.automaticallyChecksForUpdates && !updater.automaticallyChecksForUpdates)
    }

    @Test func confirmedInstallWaitsForIdleThenBlocksNewRecordingExactlyOnce() {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        activity.value = .recording
        var installed = 0
        #expect(updater.postponeInstallation { installed += 1 })
        #expect(installed == 0 && !updater.blocksNewWork)
        for work in [UpdateActivity.processing, .recovering, .fileTranscription] {
            activity.value = work
            updater.refreshActivity()
            #expect(installed == 0 && !updater.blocksNewWork)
        }
        activity.value = .idle
        updater.refreshActivity()
        #expect(installed == 1 && updater.blocksNewWork && !updater.canCheckForUpdates)
        updater.refreshActivity()
        #expect(installed == 1)
    }

    @Test func observedActivityResumesDeferredInstallWithoutPolling() async {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        activity.value = .recording
        var installed = 0
        #expect(updater.postponeInstallation { installed += 1 })
        #expect(!updater.allowsTermination)
        activity.value = .recovering
        activity.value = .idle
        for _ in 0..<10 where installed == 0 { await Task.yield() }
        #expect(installed == 1 && updater.blocksNewWork)
    }

    @Test func cancellingAnUpdateReleasesDeferredInstallAndRecording() {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        activity.value = .processing
        var installed = 0
        #expect(updater.postponeInstallation { installed += 1 })
        updater.updateFinished(error: nil)
        activity.value = .idle
        updater.refreshActivity()
        #expect(installed == 0 && !updater.blocksNewWork && updater.canCheckForUpdates)
        #expect(!updater.postponeInstallation { installed += 1 })
        #expect(updater.blocksNewWork)
        updater.updateFinished(error: NSError(domain: "UpdaterTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Update cancelled."]))
        #expect(!updater.blocksNewWork && updater.errorMessage == "Update cancelled.")
    }

    @Test func lateRelaunchCannotTerminateBusyWork() {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        activity.value = .recovering
        #expect(updater.allowsTermination)
        updater.updateWillRelaunch()
        #expect(!updater.allowsTermination && updater.blocksNewWork)
        activity.value = .idle
        updater.refreshActivity()
        #expect(updater.allowsTermination)
        updater.updateFinished(error: nil)
        #expect(!updater.blocksNewWork)
    }

    @Test func activityIncludesRecoveryAndMissingControllerIsNotIdle() {
        #expect(UpdateActivity.resolve(phase: nil, recovering: false) == .starting)
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false, transcribingFile: true) == .fileTranscription)
        #expect(UpdateActivity.resolve(phase: .idle, recovering: true) == .recovering)
        #expect(UpdateActivity.resolve(phase: .recording, recovering: false) == .recording)
        #expect(UpdateActivity.resolve(phase: .processing, recovering: false) == .processing)
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false) == .idle)
    }

    @Test func menuUsesActualEnablementAndRoutesExplicitChecks() throws {
        let activity = Activity(), driver = Driver()
        let updater = AppUpdater(driver: driver, activity: { activity.value })
        updater.start()
        let section = UpdateMenuSection(updater: updater)
        let item = try #require(section.items.first)
        #expect(item.title == "Check for Updates…" && item.isEnabled)
        _ = item.target?.perform(item.action, with: item)
        #expect(driver.checks == 1)
        activity.value = .recording
        updater.refreshActivity()
        section.refresh()
        #expect(!item.isEnabled)
    }
}
