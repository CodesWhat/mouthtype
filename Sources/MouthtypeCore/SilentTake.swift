import Foundation

/// What a take that produced no text sounded like, judged from its audio features.
public enum SilentTakeKind: Equatable, Sendable {
    /// Nothing came in at all: a muted, unplugged or wrong input.
    case noSignal
    /// Sound came in, but none of it was speech: room noise or a mic too far away.
    case noSpeech
    /// A blip of speech, too short to be a dictation. An accidental tap, not a problem with the mic.
    case tooShort
    /// Enough speech that an empty result isn't the microphone's doing.
    case spoke

    /// Peak level under which the input counts as delivering nothing.
    public static let noSignalPeakDb = -65.0
    /// Voiced audio under which speech counts as a blip.
    public static let tooShortVoicedMs = 200.0

    public static func classify(_ features: AudioFeatures) -> SilentTakeKind {
        if features.peakDb < noSignalPeakDb { return .noSignal }
        if features.voicedMs <= 0 { return .noSpeech }
        if features.voicedMs < tooShortVoicedMs { return .tooShort }
        return .spoke
    }

    /// A kind worth telling the user about: the mic, not the user's timing, is the likely cause.
    public var warrants: Bool { self == .noSignal || self == .noSpeech }
}

/// Decides whether an empty take earns a "your mic heard nothing" card. A short hold is an accidental tap, and a
/// warning that just showed isn't repeated, so a run of taps raises at most one card.
public struct SilentTakeWarning: Sendable {
    /// A hold shorter than this never warns.
    public static let minHoldMs = 1_000
    /// Seconds after a warning during which another is held back.
    public static let cooldown: TimeInterval = 30

    private var lastWarned: Date?

    public init() {}

    /// The kind to warn about, or nil when this take shouldn't raise a card. Records the warning when it returns one.
    public mutating func check(_ features: AudioFeatures, holdMs: Int, now: Date) -> SilentTakeKind? {
        let kind = SilentTakeKind.classify(features)
        guard kind.warrants, holdMs >= Self.minHoldMs else { return nil }
        if let lastWarned, now.timeIntervalSince(lastWarned) < Self.cooldown { return nil }
        lastWarned = now
        return kind
    }
}
