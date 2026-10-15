import Foundation

public struct WordTiming: Sendable, Codable, Equatable {
    public var word: String
    public var start: Double      // seconds from start of the samples
    public var end: Double
    public var confidence: Float

    public init(word: String, start: Double, end: Double, confidence: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct Transcription: Sendable, Codable, Equatable {
    public var text: String               // trimmed, same string the engine returned before
    public var words: [WordTiming]        // empty when the engine gave no timings
    public var confidence: Float?         // overall, nil when the engine gives none
    public var processingSeconds: Double  // wall time of the engine call, measured here with ContinuousClock
    public var engineID: String
    public var modelRevision: String?     // model repo/variant identifier; nil when the engine exposes none

    public init(
        text: String,
        words: [WordTiming] = [],
        confidence: Float? = nil,
        processingSeconds: Double,
        engineID: String,
        modelRevision: String? = nil
    ) {
        self.text = text
        self.words = words
        self.confidence = confidence
        self.processingSeconds = processingSeconds
        self.engineID = engineID
        self.modelRevision = modelRevision
    }
}
