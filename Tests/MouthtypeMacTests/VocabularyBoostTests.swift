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
    func transcribe(samples: [Float]) async throws -> Transcription {
        seen.append(current)
        return Transcription(text: "hello", processingSeconds: 0, engineID: "bias")
    }
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

    private func run(enabled: Bool, rules: [DictionaryRule]) async throws -> VocabularyBias? {
        let engine = BiasRecordingEngine()
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: engine, clock: SystemDictationClock())
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

    @Test func nothingSavedMeansNoBiasEvenWhenOn() async throws {
        #expect(try await run(enabled: true, rules: []) == nil)
    }

    @Test func settingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "vocab-boost-\(UUID().uuidString)")!
        #expect(!VocabularyBoostSetting.isEnabled(defaults))
        VocabularyBoostSetting.set(true, in: defaults)
        #expect(VocabularyBoostSetting.isEnabled(defaults))
    }
}
