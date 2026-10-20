import Foundation
import Testing
@testable import MouthtypeCore

private actor FileGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct FileDecoder: AudioFileDecoding {
    var decoded = DecodedAudioFile(samples: Array(repeating: 0.1, count: 32_000), durationSeconds: 2)
    let gate: FileGate?
    init(gate: FileGate? = nil) { self.gate = gate }
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        await gate?.wait()
        try Task.checkCancellation()
        return decoded
    }
}

private actor FileEngine: Transcriber {
    nonisolated let id = "file-test"
    nonisolated let displayName = "File test"
    private(set) var calls = 0
    let gate: FileGate?
    init(gate: FileGate? = nil) { self.gate = gate }
    func prepare() async throws { Issue.record("Import must use the already-prepared engine") }
    func transcribe(samples: [Float]) async throws -> Transcription {
        calls += 1
        await gate?.wait()
        return Transcription(text: "Émilie 世界 👋", processingSeconds: 0.01, engineID: id)
    }
}

private actor Order {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

private actor OrderedEngine: Transcriber {
    nonisolated let id = "ordered"
    nonisolated let displayName = "Ordered"
    let order: Order
    init(order: Order) { self.order = order }
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> Transcription {
        await order.add("transcribe")
        return Transcription(text: "hi", processingSeconds: 0.01, engineID: id)
    }
}

@Suite struct AudioFileTranscriptionTests {
    private let source = URL(fileURLWithPath: "/not-opened-by-fake/audio.wav")
    private func entered(_ gate: FileGate) async { for _ in 0..<200 where await !gate.entered { await Task.yield() } }

    @Test func decodedFileUsesExistingEngineAndReturnsExactTranscript() async throws {
        let engine = FileEngine()
        let job = AudioFileTranscription(decoder: FileDecoder(), engine: engine)
        let result = try await job.run(source)
        #expect(result.transcription.text == "Émilie 世界 👋")
        #expect(result.durationSeconds == 2)
        #expect(await engine.calls == 1)
    }

    @Test func importSetsItsOwnBiasBeforeTheEngineHearsTheAudio() async throws {
        let order = Order()
        let job = AudioFileTranscription(
            decoder: FileDecoder(), engine: OrderedEngine(order: order), beforeTranscribing: { await order.add("bias") }
        )
        _ = try await job.run(source)
        #expect(await order.events == ["bias", "transcribe"])
    }

    @Test func canceledDecodeNeverSetsABias() async {
        let gate = FileGate()
        let order = Order()
        let job = AudioFileTranscription(
            decoder: FileDecoder(gate: gate), engine: OrderedEngine(order: order), beforeTranscribing: { await order.add("bias") }
        )
        let task = Task { try await job.run(source) }
        await entered(gate)
        await job.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await order.events.isEmpty)
    }

    @Test func canceledDecodeNeverReachesEngine() async {
        let gate = FileGate()
        let engine = FileEngine()
        let job = AudioFileTranscription(decoder: FileDecoder(gate: gate), engine: engine)
        let task = Task { try await job.run(source) }
        await entered(gate)
        await job.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await engine.calls == 0)
    }

    @Test func cancellationWaitsForOldInferenceBeforeReleasingAdmission() async throws {
        let gate = FileGate()
        let job = AudioFileTranscription(decoder: FileDecoder(), engine: FileEngine(gate: gate))
        let task = Task { try await job.run(source) }
        await entered(gate)
        await job.cancel()
        await #expect(throws: AudioFileError.busy) { try await job.run(source) }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func decodedBoundsAreCheckedBeforeCallingEngine() async {
        for duration in [0, Double.nan, Double.infinity, 600.01] {
            let engine = FileEngine()
            var decoder = FileDecoder()
            decoder.decoded = DecodedAudioFile(samples: [0.1], durationSeconds: duration)
            let job = AudioFileTranscription(decoder: decoder, engine: engine)
            await #expect(throws: AudioFileError.self) { try await job.run(source) }
            #expect(await engine.calls == 0)
        }
    }
    @Test func excessDecodedSamplesAreRejectedEvenWhenDurationClaimsToFit() async {
        let engine = FileEngine()
        var decoder = FileDecoder()
        decoder.decoded = DecodedAudioFile(samples: Array(repeating: 0.1, count: AudioFileLimits.standard.maximumSamples + 1), durationSeconds: 1)
        let job = AudioFileTranscription(decoder: decoder, engine: engine)
        await #expect(throws: AudioFileError.tooLong) { try await job.run(source) }
        #expect(await engine.calls == 0)
    }

    @Test func callerCancellationPropagatesWithoutDeliveringLateInference() async {
        let gate = FileGate()
        let engine = FileEngine(gate: gate)
        let job = AudioFileTranscription(decoder: FileDecoder(), engine: engine)
        let task = Task { try await job.run(source) }
        await entered(gate)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func invalidSamplesNeverReachEngineAndFinishedJobCanBeReused() async throws {
        for samples in [[Float](), [Float.nan], [Float.infinity]] {
            let engine = FileEngine()
            var decoder = FileDecoder()
            decoder.decoded = DecodedAudioFile(samples: samples, durationSeconds: 1)
            let job = AudioFileTranscription(decoder: decoder, engine: engine)
            await #expect(throws: AudioFileError.self) { try await job.run(source) }
            #expect(await engine.calls == 0)
        }
        let engine = FileEngine()
        let job = AudioFileTranscription(decoder: FileDecoder(), engine: engine)
        _ = try await job.run(source)
        _ = try await job.run(source)
        #expect(await engine.calls == 2)
    }

}
