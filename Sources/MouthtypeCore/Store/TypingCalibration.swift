import Foundation

/// The outcome of a finished typing calibration: what was typed correctly, what was wrong, and the speed over the time that
/// actually passed. Numbers only. The typed text is never kept.
public struct TypingCalibrationResult: Equatable, Sendable {
    public let wpm: Double
    public let correctCharacters: Int
    public let errorCharacters: Int
    public let elapsed: TimeInterval

    public init(wpm: Double, correctCharacters: Int, errorCharacters: Int, elapsed: TimeInterval) {
        self.wpm = wpm
        self.correctCharacters = correctCharacters
        self.errorCharacters = errorCharacters
        self.elapsed = elapsed
    }

    /// The whole-number speed the baseline preference would store.
    public var roundedWPM: Int { Int(wpm.rounded()) }
}

/// A one-minute typing calibration as a small state machine. The clock is injected (seconds from a monotonic source), so the
/// scoring is deterministic in tests. Typing is scored five characters to a word, position by position against the passage,
/// with the characters still wrong shown separately instead of being folded into the speed.
///
/// The timer starts on the first typed character, not on Start. Stopping early scores what was typed if enough time passed;
/// cancelling (leaving the page, the app going to the background) produces no result at all.
public struct TypingCalibration: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Start was pressed; the clock is waiting for the first typed character.
        case ready
        case running(startedAt: TimeInterval)
        case finished(TypingCalibrationResult)
        /// Stopped or timed out without enough typing to score.
        case tooShort
        case cancelled
        /// A change added too many characters at once to be typing, so there is no result.
        case pasted
    }

    public static let duration: TimeInterval = 60
    /// Stopping before this many seconds is not a result.
    public static let minimumElapsed: TimeInterval = 10
    /// Outside this range the run was a fumble, not a measurement.
    /// More characters than this arriving in one change is a paste, a dictation or a drop, not typing. Autocorrect and fast
    /// typing between two observed changes stay well under it.
    public static let maximumInsertion = 8
    public static let plausibleWPM: ClosedRange<Double> = 1...400

    public let passage: [Character]
    public private(set) var phase: Phase = .idle
    public private(set) var correctCharacters = 0
    public private(set) var errorCharacters = 0
    private var typedCount = 0
    private let now: @Sendable () -> TimeInterval

    public init(passage: String, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.passage = Array(passage)
        self.now = now
    }

    public var isActive: Bool {
        switch phase {
        case .ready, .running: true
        default: false
        }
    }

    /// Seconds left on the clock: the full minute until typing starts, then counting down.
    public var remaining: TimeInterval {
        switch phase {
        case .running(let startedAt): max(0, Self.duration - (now() - startedAt))
        case .finished(let result): max(0, Self.duration - result.elapsed)
        default: Self.duration
        }
    }

    public mutating func start() {
        guard !isActive else { return }
        reset()
        phase = .ready
    }

    /// The typed text so far (the whole field, not a delta). Only counts while armed, so text typed outside a run is ignored.
    /// The text is compared and dropped. Only the two counts are kept.
    public mutating func input(_ typed: String) {
        let time = now()
        switch phase {
        case .ready:
            guard !typed.isEmpty else { return }
            guard typed.count <= Self.maximumInsertion else { markPasted(); return }
            phase = .running(startedAt: time)
        case .running:
            break
        default:
            return
        }
        guard typed.count - typedCount <= Self.maximumInsertion else { markPasted(); return }
        typedCount = typed.count
        score(typed)
        guard case .running(let startedAt) = phase else { return }
        if time - startedAt >= Self.duration {
            finish(elapsed: Self.duration)
        } else if correctCharacters + errorCharacters >= passage.count {
            finish(elapsed: time - startedAt)
        }
    }

    /// Called as time passes: ends the run at the minute mark even if no key was pressed.
    public mutating func tick() {
        guard case .running(let startedAt) = phase, now() - startedAt >= Self.duration else { return }
        finish(elapsed: Self.duration)
    }

    /// Ends a running test and scores it. Does nothing before the first typed character.
    public mutating func stop() {
        guard case .running(let startedAt) = phase else { return }
        finish(elapsed: min(Self.duration, now() - startedAt))
    }

    /// Throws the run away: no result, whatever was typed.
    public mutating func cancel() {
        guard isActive else { return }
        reset()
        phase = .cancelled
    }

    /// Back to the start for another attempt.
    public mutating func retry() {
        reset()
        phase = .idle
    }

    private mutating func markPasted() {
        reset()
        phase = .pasted
    }

    private mutating func reset() {
        typedCount = 0
        correctCharacters = 0
        errorCharacters = 0
    }

    private mutating func score(_ typed: String) {
        var correct = 0
        var wrong = 0
        for (index, character) in typed.enumerated() where index < passage.count {
            if character == passage[index] { correct += 1 } else { wrong += 1 }
        }
        correctCharacters = correct
        errorCharacters = wrong
    }

    private mutating func finish(elapsed: TimeInterval) {
        let wpm = elapsed > 0 ? Double(correctCharacters) / 5 / (elapsed / 60) : 0
        guard elapsed >= Self.minimumElapsed, Self.plausibleWPM.contains(wpm) else {
            phase = .tooShort
            return
        }
        phase = .finished(
            TypingCalibrationResult(
                wpm: wpm, correctCharacters: correctCharacters, errorCharacters: errorCharacters, elapsed: elapsed))
    }
}

/// The accepted typing speed, the one number the time-saved figures compare against. Nothing else about a calibration is stored.
public enum TypingBaselinePreference {
    public static let key = "typingBaselineWPM"
    public static let defaultWPM = StatsEngine.defaultTypingWPM

    public static func current(_ defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: key)
        return TypingCalibration.plausibleWPM.contains(stored) ? stored : defaultWPM
    }

    /// Stores a calibration result as a whole number of words per minute.
    public static func accept(_ result: TypingCalibrationResult, in defaults: UserDefaults = .standard) {
        let value = Double(result.roundedWPM)
        guard TypingCalibration.plausibleWPM.contains(value) else { return }
        defaults.set(value, forKey: key)
    }

    /// Back to the documented default.
    public static func reset(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
