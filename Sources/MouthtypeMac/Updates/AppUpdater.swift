import Foundation
import Observation

@MainActor enum UpdateActivity: Equatable {
    case starting, idle, recording, processing, recovering, fileTranscription, selectionCleanup

    static func resolve(phase: DictationController.Phase?, recovering: Bool, transcribingFile: Bool = false, editingSelection: Bool = false) -> Self {
        if recovering { return .recovering }
        if editingSelection { return .selectionCleanup }
        if transcribingFile { return .fileTranscription }
        switch phase {
        case .recording: return .recording
        case .processing: return .processing
        case .idle: return .idle
        case nil: return .starting
        }
    }
}

enum UpdateLaunchPolicy {
    static func allows(arguments: [String], bundleURL: URL, info: [String: Any]) -> Bool {
        guard arguments.count == 1, bundleURL.pathExtension == "app",
              info["SUFeedURL"] as? String == "https://mouthtype.app/updates/appcast.xml",
              let publicKey = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }
}

@MainActor protocol UpdateDriverDelegate: AnyObject {
    func mayCheckForUpdates() throws
    func postponeInstallation(_ install: @escaping () -> Void) -> Bool
    func updateAvailable()
    func updateWillRelaunch()
    func updateFinished(error: Error?)
}

@MainActor protocol UpdateDriving: AnyObject {
    var delegate: (any UpdateDriverDelegate)? { get set }
    var onChange: (() -> Void)? { get set }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor @Observable final class AppUpdater: UpdateDriverDelegate {
    private let driver: (any UpdateDriving)?
    private let activity: () -> UpdateActivity
    private var requestedStart = false
    private var observing = false
    private var started = false
    private var pendingInstall: (() -> Void)?
    private var driverCanCheck = false
    private var currentActivity = UpdateActivity.starting
    private(set) var blocksNewWork = false
    private(set) var hasUpdate = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var errorMessage: String?

    init(driver: (any UpdateDriving)?, activity: @escaping () -> UpdateActivity) {
        self.driver = driver
        self.activity = activity
        driver?.delegate = self
        driver?.onChange = { [weak self] in self?.refreshDriver() }
        refreshActivity()
        refreshDriver()
    }

    var isAvailable: Bool { driver != nil }
    var canCheckForUpdates: Bool {
        driver != nil && currentActivity == .idle && !blocksNewWork && pendingInstall == nil && (!started || driverCanCheck)
    }
    var allowsTermination: Bool { (!blocksNewWork && pendingInstall == nil) || activity() == .idle }
    var statusText: String {
        guard isAvailable else { return "Updates are available in installed Mouthtype releases." }
        if blocksNewWork { return "Installing the update. Mouthtype will reopen when it is ready." }
        if pendingInstall != nil { return "Waiting for dictation, recovery and file transcription to finish before installing." }
        if currentActivity != .idle { return "Updates wait until dictation, recovery and file transcription are finished." }
        if hasUpdate { return "An update is available. Review it when you are ready." }
        if let errorMessage { return errorMessage }
        if started, !driverCanCheck { return "An update check is already in progress." }
        return "You choose when to download and install updates."
    }

    func start() {
        guard driver != nil else { return }
        requestedStart = !started
        if !observing { observing = true; observeActivity() }
        refreshActivity()
    }

    func refreshActivity() {
        applyActivity(activity())
    }

    private func applyActivity(_ value: UpdateActivity) {
        currentActivity = value
        if requestedStart, !started, currentActivity == .idle, !blocksNewWork { requestedStart = false; startDriver() }
        if currentActivity == .idle, let install = pendingInstall {
            pendingInstall = nil
            blocksNewWork = true
            install()
        }
    }

    private func observeActivity() {
        var snapshot = UpdateActivity.starting
        withObservationTracking { snapshot = activity() } onChange: { [weak self] in
            Task { @MainActor in self?.observeActivity() }
        }
        applyActivity(snapshot)
    }

    private func startDriver() {
        guard let driver else { return }
        do { try driver.start(); started = true; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        refreshDriver()
    }

    private func refreshDriver() {
        driverCanCheck = driver?.canCheckForUpdates ?? false
        automaticallyChecksForUpdates = driver?.automaticallyChecksForUpdates ?? false
    }

    func checkForUpdates() {
        currentActivity = activity()
        guard canCheckForUpdates else { return }
        if !started { startDriver() }
        guard started, driverCanCheck else { return }
        errorMessage = nil
        hasUpdate = false
        driver?.checkForUpdates()
        refreshDriver()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let driver else { return }
        driver.automaticallyChecksForUpdates = enabled
        refreshDriver()
    }

    func mayCheckForUpdates() throws {
        guard activity() == .idle, !blocksNewWork, pendingInstall == nil else {
            throw NSError(domain: "MouthtypeUpdates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finish dictation, recovery, file transcription or selected-text editing before checking for updates."])
        }
    }

    func postponeInstallation(_ install: @escaping () -> Void) -> Bool {
        if activity() == .idle { blocksNewWork = true; return false }
        pendingInstall = install
        return true
    }

    func updateAvailable() { hasUpdate = true; refreshActivity() }
    func updateWillRelaunch() { blocksNewWork = true }

    func updateFinished(error: Error?) {
        pendingInstall = nil
        blocksNewWork = false
        hasUpdate = false
        if let error = error as NSError?, error.domain != "MouthtypeUpdates" { errorMessage = error.localizedDescription }
        else { errorMessage = nil }
        refreshDriver()
    }
}
