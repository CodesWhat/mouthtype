import Foundation
import MouthtypeCore
import Observation

/// The model behind the Stats page's typing calibration. The scoring is `TypingCalibration` in the core target; this adds the
/// minute-long ticker, the typed text for the field (kept in memory for the run only), and the accepted-speed preference.
/// Only an accepted whole-number speed is ever written, and only to the defaults it was given.
@MainActor @Observable final class TypingCalibrationModel {
    /// Plain prose with some punctuation, long enough that a fast typist doesn't run out inside the minute. The first
    /// sentence is the website's speed check.
    static let passage =
        "I finished the draft and will send it over before lunch, so take a look when you have a minute and let me know "
        + "what you think. The meeting moved to Thursday afternoon, which gives everyone time to read the notes first. "
        + "If anything looks off, leave a comment and I will sort it out tonight. Thanks again for the quick turnaround, "
        + "it really helped. Next week we can pick up the second half of the plan, starting with the schedule and the "
        + "budget, then move on to who owns what. Keep the list short, keep the dates honest, and send me whatever "
        + "questions come up along the way."

    private(set) var calibration: TypingCalibration
    /// What is in the field. Cleared on every Start and Retry. Never written anywhere.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            calibration.input(text)
            syncTicker()
        }
    }
    private(set) var remaining: TimeInterval = TypingCalibration.duration
    /// True while the calibration area is open on the page.
    var isOpen = false
    private(set) var baseline: Double

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onAccepted: @MainActor () -> Void
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        defaults: UserDefaults, passage: String = TypingCalibrationModel.passage,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onAccepted: @escaping @MainActor () -> Void = {}
    ) {
        self.defaults = defaults
        self.onAccepted = onAccepted
        self.sleep = sleep
        calibration = TypingCalibration(passage: passage, now: now)
        baseline = TypingBaselinePreference.current(defaults)
    }

    isolated deinit { ticker?.cancel() }

    var phase: TypingCalibration.Phase { calibration.phase }
    var isCustomBaseline: Bool { baseline != TypingBaselinePreference.defaultWPM }
    var result: TypingCalibrationResult? {
        if case .finished(let result) = calibration.phase { return result }
        return nil
    }

    /// Opens the calibration area. Nothing runs until Start.
    func open() { isOpen = true }

    /// Closes the area and throws away any run in progress.
    func close() {
        cancel()
        isOpen = false
    }

    func start() {
        text = ""
        calibration.start()
        remaining = TypingCalibration.duration
        syncTicker()
    }

    /// Ends a running test and scores it.
    func stop() {
        calibration.stop()
        syncTicker()
        remaining = calibration.remaining
    }

    /// The window lost focus or the page went away: no result, whatever was typed.
    func cancel() {
        guard calibration.isActive else { return }
        calibration.cancel()
        text = ""
        syncTicker()
        remaining = TypingCalibration.duration
    }

    func retry() {
        calibration.retry()
        text = ""
        remaining = TypingCalibration.duration
        syncTicker()
    }

    /// Keeps the result as the typing speed. The prior baseline stands until this is called.
    func accept() {
        guard let result else { return }
        TypingBaselinePreference.accept(result, in: defaults)
        baseline = TypingBaselinePreference.current(defaults)
        calibration.retry()
        text = ""
        remaining = TypingCalibration.duration
        onAccepted()
    }

    /// Back to the documented default.
    func reset() {
        TypingBaselinePreference.reset(in: defaults)
        baseline = TypingBaselinePreference.current(defaults)
        onAccepted()
    }

    /// Advances the clock once. The ticker calls this; tests call it directly.
    func tick() {
        calibration.tick()
        remaining = calibration.remaining
        syncTicker()
    }

    private func syncTicker() {
        remaining = calibration.remaining
        guard case .running = calibration.phase else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let wait = sleep
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await wait(.milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }
}
