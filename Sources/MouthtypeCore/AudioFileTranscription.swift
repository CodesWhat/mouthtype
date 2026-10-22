import Foundation

public struct AudioFileLimits: Sendable {
    public static let standard = AudioFileLimits()
    public let maximumSeconds = 600.0
    public let maximumSamples = 9_601_024
    public let maximumSourceBytes = 512 * 1024 * 1024
    public init() {}
}

public enum AudioFileError: Error, Equatable {
    case busy, empty, unsupportedFormat, tooLong, tooLarge, invalidAudio, cannotReplaceSource
}

public struct DecodedAudioFile: Sendable {
    public let samples: [Float]  // 16 kHz mono, matching Transcriber input.
    public let durationSeconds: Double
    public init(samples: [Float], durationSeconds: Double) {
        self.samples = samples
        self.durationSeconds = durationSeconds
    }
}

public protocol AudioFileDecoding: Sendable {
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile
}

public struct AudioFileTranscript: Sendable {
    public let transcription: Transcription
    public let durationSeconds: Double
}

public actor AudioFileTranscription {
    private let decoder: any AudioFileDecoding
    private let engine: any Transcriber
    private let beforeTranscribing: @Sendable () async -> Void
    private var current: Task<AudioFileTranscript, Error>?
    /// `beforeTranscribing` runs right before the engine hears the audio, so an import sets its own recognition bias
    /// (the saved words only) instead of inheriting whatever the last dictation left on the shared engine.
    public init(
        decoder: any AudioFileDecoding, engine: any Transcriber, beforeTranscribing: @escaping @Sendable () async -> Void = {}
    ) {
        self.decoder = decoder
        self.engine = engine
        self.beforeTranscribing = beforeTranscribing
    }
    public func run(_ url: URL, didDecode: @escaping @Sendable () async -> Void = {}) async throws -> AudioFileTranscript {
        guard current == nil else { throw AudioFileError.busy }
        try Task.checkCancellation()
        let decoder = decoder
        let engine = engine
        let beforeTranscribing = beforeTranscribing
        let task = Task {
            let limits = AudioFileLimits.standard
            let audio = try await decoder.decode(url, limits: limits)
            try Task.checkCancellation()
            guard audio.durationSeconds.isFinite, audio.durationSeconds > 0 else { throw AudioFileError.invalidAudio }
            guard audio.durationSeconds <= limits.maximumSeconds, audio.samples.count <= limits.maximumSamples else { throw AudioFileError.tooLong }
            guard !audio.samples.isEmpty else { throw AudioFileError.empty }
            guard audio.samples.allSatisfy(\.isFinite) else { throw AudioFileError.invalidAudio }
            await didDecode()
            try Task.checkCancellation()
            await beforeTranscribing()
            try Task.checkCancellation()
            let transcription = try await engine.transcribe(samples: audio.samples)
            try Task.checkCancellation()
            return AudioFileTranscript(transcription: transcription, durationSeconds: audio.durationSeconds)
        }
        current = task
        defer { if current == task { current = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    public func cancel() { current?.cancel() }
}

extension AudioFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .busy: "Finish or cancel the current task first."
        case .empty: "The file contains no audio."
        case .unsupportedFormat: "Choose a WAV, AIFF or M4A audio file."
        case .tooLong: "Choose an audio file no longer than 10 minutes."
        case .tooLarge: "Choose an audio file no larger than 512 MB."
        case .invalidAudio: "The audio file could not be read. Your original is unchanged."
        case .cannotReplaceSource: "Choose a different name. The original audio file is preserved."
        }
    }
}
