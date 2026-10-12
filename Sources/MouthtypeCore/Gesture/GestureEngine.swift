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

public enum GestureEvent: Equatable, Sendable {
    case pressed
    case released
    case cancelled(CancelReason)
    case discarded(DiscardReason)
}

/// Hex's processor plus the recording-length judgement, giving the four outcomes the app acts on.
/// The press is reported at once; whether the hold was long enough is decided at release.
public struct GestureEngine: Sendable {
    public private(set) var processor: HotKeyProcessor
    private let configuration: GestureConfiguration
    private var recordingStart: Date?

    public init(configuration: GestureConfiguration = .default) {
        self.configuration = configuration
        processor = configuration.makeProcessor()
    }

    public var isRecording: Bool { processor.isMatched }

    public mutating func process(_ keyEvent: KeyEvent, now: Date) -> GestureEvent? {
        guard let output = processor.process(keyEvent: keyEvent, now: now) else { return nil }
        return translate(output, now: now)
    }

    public mutating func processMouseClick(now: Date) -> GestureEvent? {
        guard let output = processor.processMouseClick(now: now) else { return nil }
        return translate(output, now: now)
    }

    private mutating func translate(_ output: HotKeyProcessor.Output, now: Date) -> GestureEvent? {
        switch output {
        case .startRecording:
            recordingStart = now
            return .pressed
        case .stopRecording:
            defer { recordingStart = nil }
            let decision = RecordingDecisionEngine.decide(.init(
                hotkey: configuration.hotkey,
                minimumKeyTime: configuration.minimumKeyTime,
                recordingStartTime: recordingStart,
                currentTime: now
            ))
            return decision == .proceedToTranscription ? .released : .discarded(.tooShort)
        case .cancel:
            recordingStart = nil
            return .cancelled(.escape)
        case .discard:
            recordingStart = nil
            return .discarded(.otherInput)
        }
    }
}
