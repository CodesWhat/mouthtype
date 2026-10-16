import Foundation
import Sparkle

@MainActor final class SparkleDriver: NSObject, UpdateDriving, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    weak var delegate: (any UpdateDriverDelegate)?
    var onChange: (() -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var availabilityObservation: NSKeyValueObservation?
    private var checksObservation: NSKeyValueObservation?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
        checksObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try delegate?.mayCheckForUpdates()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updates { try delegate?.mayCheckForUpdates() }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        delegate?.postponeInstallation(installHandler) ?? true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { delegate?.updateAvailable() }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { delegate?.updateWillRelaunch() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let failure = error as NSError?
        let ordinaryOutcome = failure?.domain == SUSparkleErrorDomain
            && (failure?.code == Int(SUError.noUpdateError.rawValue) || failure?.code == Int(SUError.installationCanceledError.rawValue))
        delegate?.updateFinished(error: ordinaryOutcome ? nil : error)
    }
}
