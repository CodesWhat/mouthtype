import Foundation

public enum CancelReason: Equatable, Sendable {
    case escape
    /// The tap went away mid-recording and the release was never seen.
    case inputLost
}

public enum DiscardReason: Equatable, Sendable {
    /// Released before the minimum hold.
    case tooShort
    /// Another key, modifier or click arrived early in the hold.
    case otherInput
}

public enum LockTrigger: Equatable, Sendable {
    /// A quick tap followed by a second press.
    case doubleTap
    /// Space pressed while the hotkey was held.
    case fnSpace
    case toggle
}

public enum GestureEvent: Equatable, Sendable {
    case pressed
    case released
    /// The recording stays open with no key held. The next tap of the hotkey ends it with `.released`.
    case locked(LockTrigger)
    case cancelled(CancelReason)
    case discarded(DiscardReason)
}

/// Hex's processor plus the recording-length judgement, giving the four outcomes the app acts on.
/// The press is reported at once; whether the hold was long enough is decided at release.
public struct GestureEngine: Sendable {
    public private(set) var processor: HotKeyProcessor
    private let configuration: GestureConfiguration
    private var recordingStart: Date?
    private var locked = false

    public init(configuration: GestureConfiguration = .default) {
        self.configuration = configuration
        processor = configuration.makeProcessor()
    }

    public var isRecording: Bool { processor.isMatched }
    public var isLocked: Bool { processor.isLocked }

    public mutating func process(_ keyEvent: KeyEvent, now: Date) -> GestureEvent? {
        let before = processor.state
        return resolve(processor.process(keyEvent: keyEvent, now: now), before: before, now: now)
    }

    public mutating func processMouseClick(now: Date) -> GestureEvent? {
        let before = processor.state
        return resolve(processor.processMouseClick(now: now), before: before, now: now)
    }

    /// Space while the hotkey is held: locks the hold in progress. Nil when no hold is in progress.
    public mutating func lockFromChord() -> GestureEvent? {
        guard processor.lockCurrentHold() else { return nil }
        locked = true
        return .locked(.fnSpace)
    }

    /// Leaves a lock without a gesture (a menu stop, the safety cap), so the next press starts fresh.
    public mutating func endLock() {
        guard processor.endLock() else { return }
        locked = false
        recordingStart = nil
    }

    private mutating func resolve(_ output: HotKeyProcessor.Output?, before: HotKeyProcessor.State, now: Date) -> GestureEvent? {
        if let output { return translate(output, now: now) }
        // The processor locks on the second release without an output of its own.
        guard processor.isLocked, before != .doubleTapLock else { return nil }
        locked = true
        return .locked(.doubleTap)
    }

    private mutating func translate(_ output: HotKeyProcessor.Output, now: Date) -> GestureEvent? {
        switch output {
        case .startRecording:
            recordingStart = now
            locked = processor.isLocked
            return .pressed
        case .stopRecording:
            defer {
                recordingStart = nil
                locked = false
            }
            // A lock was deliberate, so stopping it never counts as too short.
            if locked { return .released }
            let decision = RecordingDecisionEngine.decide(.init(
                hotkey: configuration.hotkey,
                minimumKeyTime: configuration.minimumKeyTime,
                recordingStartTime: recordingStart,
                currentTime: now
            ))
            guard decision == .proceedToTranscription else { return .discarded(.tooShort) }
            // A real hold followed by a quick tap is not a double-tap.
            processor.forgetLastTap()
            return .released
        case .cancel:
            recordingStart = nil
            locked = false
            return .cancelled(.escape)
        case .discard:
            recordingStart = nil
            locked = false
            return .discarded(.otherInput)
        }
    }
}
