import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor
private final class TakeCapture: DictationCapturing {
    var isPrepared = true
    var audio: CapturedAudio
    var started = 0
    init(audio: CapturedAudio) { self.audio = audio }
    func start(keyDownAtNanos: UInt64) async throws { started += 1 }
    func stop() async throws -> CapturedAudio { audio }
    func cancel() async {}
}

@MainActor
private final class TakeEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    var calls = 0
    var languages: [DictationLanguageRequest] = []
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        languages.append(language)
        return try await transcribe(samples: samples)
    }
    func transcribe(samples: [Float]) async throws -> Transcription {
        calls += 1
        return Transcription(text: "hello there", processingSeconds: 0, engineID: "fake")
    }
    func setVocabularyBias(_ bias: VocabularyBias?) async {}
}

@MainActor
@Suite struct SetupTestTakeTests {
    private func audio(_ level: Float) -> CapturedAudio {
        let samples = (0..<16_000).map { level * sin(Float($0) * 0.2) }
        return CapturedAudio(
            samples: samples, sampleRate: 16_000, deviceUID: nil, deviceName: "Desk Mic", deviceTransport: "usb",
            firstSampleMs: 0, firstNonzeroMs: nil, captureStartMs: 0, audioMs: 1_000)
    }

    private func take(_ audio: CapturedAudio, canStart: Bool = true) -> (SetupTestTake, TakeCapture, TakeEngine) {
        let capture = TakeCapture(audio: audio)
        let engine = TakeEngine()
        let take = SetupTestTake(
            capture: capture, engine: engine, readLevel: { -20 }, canStart: { canStart },
            language: { .english }, sleep: { _ in await Task.yield() })
        return (take, capture, engine)
    }

    private func finish(_ take: SetupTestTake) async {
        for _ in 0..<2_000 where take.isBusy { await Task.yield() }
    }

    @Test func aTestTakeKeepsTheLanguageChosenWhenItStarts() async {
        @MainActor final class Choice { var value = DictationLanguageRequest.explicit(.german) }
        let choice = Choice()
        let capture = TakeCapture(audio: audio(0.3))
        let engine = TakeEngine()
        let take = SetupTestTake(
            capture: capture, engine: engine, readLevel: { -20 }, canStart: { true },
            language: { choice.value }, sleep: { _ in await Task.yield() })
        take.start()
        choice.value = .explicit(.japanese)
        await finish(take)
        #expect(engine.languages == [.explicit(.german)])
    }

    @Test func aSpokenTakeShowsTheTranscriptAndLevel() async {
        let (take, capture, engine) = take(audio(0.3))
        take.start()
        await finish(take)
        guard case let .finished(outcome) = take.state else { Issue.record("not finished: \(take.state)"); return }
        #expect(outcome.transcript == "hello there" && outcome.heardSpeech)
        #expect(outcome.micName == "Desk Mic")
        #expect(capture.started == 1 && engine.calls == 1)
    }

    @Test func aSilentTakeSkipsTheEngineAndNamesNoSignal() async {
        let (take, _, engine) = take(audio(0))
        take.start()
        await finish(take)
        guard case let .finished(outcome) = take.state else { Issue.record("not finished: \(take.state)"); return }
        #expect(outcome.transcript.isEmpty && outcome.kind == .noSignal)
        #expect(engine.calls == 0)
    }

    @Test func aDictationInProgressRefusesTheTake() async {
        let (take, capture, _) = take(audio(0.3), canStart: false)
        take.start()
        guard case .failed = take.state else { Issue.record("expected failure: \(take.state)"); return }
        #expect(capture.started == 0)
    }

    @Test func theMeterMapsDecibelsOntoZeroToOne() {
        #expect(SetupTestTake.meterFraction(db: -120) == 0)
        #expect(SetupTestTake.meterFraction(db: -30) == 0.5)
        #expect(SetupTestTake.meterFraction(db: 0) == 1)
    }
}
