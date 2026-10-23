import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
private final class BiasRecordingEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    /// The bias in force at each transcribe call.
    var seen: [VocabularyBias?] = []
    private var current: VocabularyBias?
    func setVocabularyBias(_ bias: VocabularyBias?) async { current = bias }
    var languages: [DictationLanguageRequest] = []
    func transcribe(samples: [Float]) async throws -> Transcription {
        seen.append(current)
        return Transcription(text: "hello", processingSeconds: 0, engineID: "bias")
    }
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        languages.append(language)
        return try await transcribe(samples: samples)
    }
}

@MainActor
private final class BoostedEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(
            text: "hi Maya", words: [WordTiming(word: "hi", start: 0, end: 0.2, confidence: 1), WordTiming(word: "Maya", start: 0.2, end: 0.6, confidence: 1)],
            processingSeconds: 0, engineID: "boosted", boostTermsApplied: ["Maya"]
        )
    }
}

private final class RecordingStore: DictationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: TranscriptionRecord?
    var transcription: TranscriptionRecord? { lock.withLock { saved } }
    func begin(_ start: DictationStart) async throws {}
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws {}
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws { lock.withLock { saved = record } }
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws {}
    func recordInsertVerdict(_ id: String, outcome: String, pasteReceiptMs: Int?) async throws {}
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws {}
    func reopen(_ id: String) async throws {}
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {}
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws {}
}

private struct SavedRules: VocabularyProviding {
    var rules: [DictionaryRule]
    func dictionary() -> [DictionaryRule] { rules }
    func snippets() -> [Snippet] { [] }
}

@MainActor
@Suite struct VocabularyBoostTests {
    private let rules = [DictionaryRule(heard: "maya", written: "Maya"), DictionaryRule(heard: "dry dock", written: "Drydock")]

    private func audio() -> CapturedAudio {
        let samples = (0..<16_000).map { Float(0.4 * sin(Double($0) * 0.2)) }
        return CapturedAudio(
            samples: samples, sampleRate: 16_000, deviceUID: nil, deviceName: nil, deviceTransport: "test",
            firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 1000
        )
    }

    private func run(
        enabled: Bool, rules: [DictionaryRule], language: DictationLanguageRequest = .english
    ) async throws -> VocabularyBias? {
        let engine = BiasRecordingEngine()
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: engine, clock: SystemDictationClock())
        pipeline.languageRequest = { language }
        pipeline.vocabulary = SavedRules(rules: rules)
        pipeline.boostSavedWords = { enabled }
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos())
        _ = try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
        #expect(engine.seen.count == 1)
        return engine.seen.first ?? nil
    }

    @Test func requestCarriesSavedSpellingsWhenOn() async throws {
        let bias = try await run(enabled: true, rules: rules)
        #expect(bias?.terms == ["Maya", "Drydock"])
    }

    @Test func requestCarriesNothingWhenOff() async throws {
        #expect(try await run(enabled: false, rules: rules) == nil)
    }

    @Test func aTakeThatCannotBeEnglishGetsNoBias() async throws {
        #expect(try await run(enabled: true, rules: rules, language: .explicit(.german)) == nil)
        #expect(try await run(enabled: true, rules: rules, language: .auto(candidates: [.english, .german]))?.terms == ["Maya", "Drydock"])
    }

    @Test func theEngineGetsTheRequestAndTheStoreGetsTheLanguage() async throws {
        let engine = BiasRecordingEngine()
        let store = RecordingStore()
        var pipeline = DictationPipeline(store: store, archive: nil, engine: engine, clock: SystemDictationClock())
        pipeline.languageRequest = { .explicit(.german) }
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos(), rowOpen: true)
        _ = try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
        #expect(engine.languages == [.explicit(.german)])
        #expect(store.transcription?.language == "de")
    }

    @Test func nothingSavedMeansNoBiasEvenWhenOn() async throws {
        #expect(try await run(enabled: true, rules: []) == nil)
    }

    @Test func pipelineUsesTheRescoredTextAndRecordsTheAppliedTerms() async throws {
        let store = RecordingStore()
        var pipeline = DictationPipeline(store: store, archive: nil, engine: BoostedEngine(), clock: SystemDictationClock())
        pipeline.boostSavedWords = { true }
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos(), rowOpen: true)
        let result = try #require(try await pipeline.transcribe(audio(), session: session, voicedMs: 1000))
        #expect(result.text == "hi Maya")
        #expect(result.words.map(\.word) == ["hi", "Maya"])
        let record = try #require(store.transcription)
        #expect(record.boostTerms == ["Maya"])
        #expect(record.transcription.text == "hi Maya")
    }

    @Test func settingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "vocab-boost-\(UUID().uuidString)")!
        #expect(!VocabularyBoostSetting.isEnabled(defaults))
        VocabularyBoostSetting.set(true, in: defaults)
        #expect(VocabularyBoostSetting.isEnabled(defaults))
    }
}
