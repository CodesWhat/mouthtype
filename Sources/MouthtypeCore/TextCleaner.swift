import Foundation

public struct CleanupContext: Sendable, Equatable, Hashable {
    /// Custom terms the output must spell exactly.
    public var vocabulary: [String]
    /// The app the text will be pasted into, when known.
    public var appName: String?
    /// The control line for S1-mini. Other cleaners ignore it.
    public var s1Controls: S1MiniControls
    public var level: CleanupLevel
    public var before: String?
    public var after: String?
    public var correctionsOnly: Bool

    public init(vocabulary: [String] = [], appName: String? = nil, s1Controls: S1MiniControls = .benchmark,
                level: CleanupLevel = .light, before: String? = nil, after: String? = nil, correctionsOnly: Bool = false) {
        self.vocabulary = vocabulary
        self.appName = appName
        self.s1Controls = s1Controls
        self.level = level
        self.before = before.flatMap { value in
            let bounded = String(value.suffix(600))
            return bounded.allSatisfy(\.isWhitespace) ? nil : bounded
        }
        self.after = after.flatMap { value in
            let bounded = String(value.prefix(300))
            return bounded.allSatisfy(\.isWhitespace) ? nil : bounded
        }
        self.correctionsOnly = correctionsOnly
    }
}

public protocol TextCleaner: Sendable {
    var id: String { get }                 // stable slug, e.g. "gemma-4-e2b-it-4bit"
    var displayName: String { get }
    var usesNativeControls: Bool { get }
    func prepare() async throws            // download if needed + load; idempotent
    func clean(_ transcript: String, context: CleanupContext) async throws -> String
}

extension TextCleaner {
    public var usesNativeControls: Bool { false }
}

public struct CleanupResult: Sendable, Equatable {
    public var text: String
    /// Seconds from the start of the call to the first non-empty output. Equal to `totalSeconds` for non-streaming cleaners.
    public var firstOutputSeconds: Double
    public var totalSeconds: Double
    public var outputTokens: Int?
    /// Seconds spent decoding after the prompt was processed, when the backend reports it.
    public var generationSeconds: Double?

    public init(text: String, firstOutputSeconds: Double, totalSeconds: Double, outputTokens: Int? = nil, generationSeconds: Double? = nil) {
        self.text = text
        self.firstOutputSeconds = firstOutputSeconds
        self.totalSeconds = totalSeconds
        self.outputTokens = outputTokens
        self.generationSeconds = generationSeconds
    }
}

/// Implemented by cleaners that stream, so the bench can time first output and total latency.
public protocol MeasuredCleaner: TextCleaner {
    /// Where the model lives on disk, or nil when there is no local model.
    var modelDirectory: URL? { get }
    /// True when the timing columns do not describe an API call (for example a CLI round trip).
    var timingsAreRepresentative: Bool { get }
    /// Whether this cleaner receives the shared system prompt. False for models that need their own native prompt.
    var usesSharedPrompt: Bool { get }
    var license: String? { get }
    func prepareMeasured() async throws -> PrepareTimings
    func cleanMeasured(_ transcript: String, context: CleanupContext) async throws -> CleanupResult
}

extension MeasuredCleaner {
    public var timingsAreRepresentative: Bool { true }
    public var usesSharedPrompt: Bool { true }
    public var license: String? { nil }

    public func prepare() async throws {
        _ = try await prepareMeasured()
    }

    public func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        try await cleanMeasured(transcript, context: context).text
    }
}

public enum CleanerError: Error, LocalizedError, Equatable {
    case notPrepared(id: String)
    /// The cleaner cannot run on this machine right now. Reported as a status, not as a failure.
    case unavailable(reason: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .notPrepared(id): return "Cleaner '\(id)' used before prepare()"
        case let .unavailable(reason): return reason
        case let .failed(message): return message
        }
    }
}

public enum CleanupLimits {
    /// Cap on generated tokens: a small multiple of the input length, with a floor for tiny inputs.
    public static func maxOutputTokens(for transcript: String) -> Int {
        TextMetrics.wordCount(transcript) * 3 + 48
    }
}
