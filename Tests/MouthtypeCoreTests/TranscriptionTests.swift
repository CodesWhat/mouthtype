import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct TranscriptionTests {
    @Test func codableRoundTrip() throws {
        let original = Transcription(
            text: "hello world",
            words: [
                WordTiming(word: "hello", start: 0, end: 0.4, confidence: 0.9),
                WordTiming(word: "world", start: 0.5, end: 0.9, confidence: 0.75),
            ],
            confidence: 0.8,
            processingSeconds: 0.12,
            engineID: "parakeet-tdt-v3",
            modelRevision: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Transcription.self, from: data) == original)
    }

    @Test func codableRoundTripWithNilOptionals() throws {
        let original = Transcription(text: "", processingSeconds: 0, engineID: "x")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcription.self, from: data)
        #expect(decoded == original)
        #expect(decoded.confidence == nil)
        #expect(decoded.modelRevision == nil)
    }
}
