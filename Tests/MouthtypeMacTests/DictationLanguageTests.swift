import Foundation
import MouthtypeCore
import Testing

@testable import MouthtypeMac

private struct FixedDetector: LanguageDetector {
    var answer: DictationLanguage
    var confidence = 0.95

    func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)] {
        [(answer, confidence)]
    }
}

@MainActor
private final class TextEngine: DictationEngine {
    let text: String
    init(text: String) { self.text = text }
    var readiness: EngineReadiness { .ready }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: text, processingSeconds: 0, engineID: "text")
    }
}

@Suite struct DictationLanguageSettingTests {
    @Test func candidatesAreTheSupportedPreferredLanguagesWithEnglish() {
        #expect(DictationLanguageSetting.candidates(preferredLanguages: ["en-US"]) == [.english])
        #expect(DictationLanguageSetting.candidates(preferredLanguages: []) == [.english])
        #expect(DictationLanguageSetting.candidates(preferredLanguages: ["ja-JP"]) == [.japanese, .english])
        #expect(DictationLanguageSetting.candidates(preferredLanguages: ["en-US", "de-DE", "ja-JP", "pt-BR"]) == [.english, .german, .japanese, .portuguese])
        #expect(DictationLanguageSetting.candidates(preferredLanguages: ["de-DE", "de-AT"]) == [.german, .english])
        #expect(DictationLanguageSetting.candidates(preferredLanguages: ["fr", "en", "fr-CA"]) == [.french, .english])
    }

    @Test func autoOnAnEnglishOnlyMacIsTheEnglishRequest() {
        #expect(DictationLanguageSetting.auto.request(preferredLanguages: ["en-GB"]).resolved == .english)
        #expect(DictationLanguageSetting.auto.request(preferredLanguages: ["en-GB"]).parakeetHint == .english)
        #expect(DictationLanguageSetting.auto.request(preferredLanguages: ["en", "ru"]).resolved == nil)
        #expect(DictationLanguageSetting.explicit(.polish).request(preferredLanguages: ["en"]) == .explicit(.polish))
    }

    @Test func defaultsToAutoAndRoundTrips() throws {
        let name = "mouthtype.language.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DictationLanguageSetting.load(defaults) == .auto)
        DictationLanguageSetting.set(.explicit(.german), in: defaults)
        #expect(DictationLanguageSetting.load(defaults) == .explicit(.german))
        DictationLanguageSetting.set(.auto, in: defaults)
        #expect(DictationLanguageSetting.load(defaults) == .auto)
        defaults.set("xx", forKey: DictationLanguageSetting.key)
        #expect(DictationLanguageSetting.load(defaults) == .auto)
    }
}

@MainActor
@Suite struct DictationPipelineLanguageTests {
    private func audio() -> CapturedAudio {
        let samples = (0..<16_000).map { Float(0.4 * sin(Double($0) * 0.2)) }
        return CapturedAudio(
            samples: samples, sampleRate: 16_000, deviceUID: nil, deviceName: nil, deviceTransport: "test",
            firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 1000
        )
    }

    private func transcribe(
        _ text: String, request: DictationLanguageRequest, detector: (any LanguageDetector)?
    ) async throws -> TranscribedDictation? {
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: TextEngine(text: text), clock: SystemDictationClock())
        pipeline.languageRequest = { request }
        pipeline.languageResolver = LanguageResolver(detector: detector)
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos())
        return try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
    }

    @Test func aQueuedTakeKeepsItsCapturedLanguageAfterTheSettingChanges() async throws {
        final class Engine: DictationEngine {
            var readiness: EngineReadiness { .ready }
            var seen: DictationLanguageRequest?
            func transcribe(samples: [Float]) async throws -> Transcription {
                Transcription(text: "Das ist ein deutscher Satz.", processingSeconds: 0, engineID: "test")
            }
            func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
                seen = language
                return try await transcribe(samples: samples)
            }
        }
        let engine = Engine()
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: engine, clock: SystemDictationClock())
        pipeline.languageRequest = { .english }
        let clock = SystemDictationClock()
        let session = DictationSession(
            id: "captured-language", startedAt: clock.now(), keyDownAt: clock.nowNanos(), languageRequest: .explicit(.german))
        let result = try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
        #expect(engine.seen == .explicit(.german))
        #expect(result?.language == .german)
    }

    private let german = "Das ist ein ganz normaler deutscher Satz."

    @Test func autoWithSeveralCandidatesCarriesTheDetectedLanguage() async throws {
        let taken = try await transcribe(german, request: .auto(candidates: [.english, .german]), detector: FixedDetector(answer: .german))
        #expect(taken?.language == .german)
    }

    @Test func autoFallsBackToTheFirstCandidateUnderTheThreshold() async throws {
        let taken = try await transcribe(
            german, request: .auto(candidates: [.english, .german]), detector: FixedDetector(answer: .german, confidence: 0.2))
        #expect(taken?.language == .english)
    }

    @Test func aSettledRequestDoesNotDetect() async throws {
        let one = try await transcribe(german, request: .auto(candidates: [.english]), detector: FixedDetector(answer: .german))
        #expect(one?.language == .english)
        let explicit = try await transcribe(german, request: .explicit(.polish), detector: FixedDetector(answer: .german))
        #expect(explicit?.language == .polish)
    }

    @Test func theDetectedLanguageGatesTheEnglishOnlyStages() async throws {
        let spoken = "um drei Uhr bin ich da"
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: TextEngine(text: spoken), clock: SystemDictationClock())
        pipeline.languageRequest = { .auto(candidates: [.english, .german]) }
        pipeline.languageResolver = LanguageResolver(detector: FixedDetector(answer: .german))
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos())
        let taken = try #require(try await pipeline.transcribe(audio(), session: session, voicedMs: 1000))
        let cleaned = await pipeline.clean(
            taken, inputs: pipeline.cleanupInputs(level: .basic), context: nil, clipboard: nil)
        #expect(cleaned.text.lowercased().hasPrefix("um drei uhr"))
        // The same text read as English loses its leading filler.
        var english = taken
        english.language = .english
        let asEnglish = await pipeline.clean(
            english, inputs: pipeline.cleanupInputs(level: .basic), context: nil, clipboard: nil)
        #expect(!asEnglish.text.lowercased().hasPrefix("um "))
    }
}
