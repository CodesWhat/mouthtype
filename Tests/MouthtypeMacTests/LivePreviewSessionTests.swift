import Foundation
import Testing
@testable import MouthtypeMac

private actor PreviewGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private(set) var calls = 0
    func wait() async {
        calls += 1
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() } else { permits += 1 }
    }
}

private actor PreviewRecognizer {
    private let gate: PreviewGate?
    private(set) var counts: [Int] = []
    private(set) var concurrent = 0
    private(set) var maximumConcurrent = 0
    var result = "These are provisional words."
    init(gate: PreviewGate? = nil) { self.gate = gate }
    func run(_ samples: [Float]) async throws -> String {
        counts.append(samples.count)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        await gate?.wait()
        concurrent -= 1
        return result
    }
}

@MainActor
private final class PreviewCount { var value = 16_000 }

@MainActor
@Suite struct LivePreviewSessionTests {
    private func settle() async { for _ in 0..<100 { await Task.yield() } }

    @Test func previewWaitsForCadenceThenUsesBoundedAudio() async {
        let cadence = PreviewGate()
        let recognizer = PreviewRecognizer()
        let preview = LivePreviewSession(pause: { await cadence.wait() })
        var requested: [Int] = []
        var texts: [String] = []
        preview.start(
            source: { maximum in
                requested.append(maximum)
                return PreviewAudio(samples: Array(repeating: 0.1, count: maximum + 10), capturedSampleCount: 200_000)
            }, recognize: { try await recognizer.run($0) }, update: { texts.append($0) })
        await settle()
        #expect(requested.isEmpty)
        await cadence.release()
        await settle()
        #expect(requested == [128_000])
        #expect(await recognizer.counts == [128_000])
        #expect(texts == ["These are provisional words."])
        preview.stop()
        await cadence.release()
        await settle()
    }

    @Test func shortAndUnchangedAudioDoesNotRepeatInference() async {
        let cadence = PreviewGate()
        let recognizer = PreviewRecognizer()
        let preview = LivePreviewSession(pause: { await cadence.wait() })
        let count = PreviewCount()
        preview.start(
            source: { _ in PreviewAudio(samples: Array(repeating: 0.1, count: count.value), capturedSampleCount: count.value) }, recognize: { try await recognizer.run($0) }, update: { _ in })
        await settle()
        await cadence.release()
        await settle()
        #expect(await recognizer.counts.isEmpty)
        count.value = 48_000
        await cadence.release()
        await settle()
        await cadence.release()
        await settle()
        #expect(await recognizer.counts == [48_000])
        preview.stop()
        await cadence.release()
        await settle()
    }

    @Test func stoppedInferenceNeverPublishesAndNewSessionWaitsForIt() async {
        let cadence = PreviewGate()
        let inference = PreviewGate()
        let recognizer = PreviewRecognizer(gate: inference)
        let preview = LivePreviewSession(pause: { await cadence.wait() })
        var texts: [String] = []
        let source: LivePreviewSession.Source = { _ in PreviewAudio(samples: Array(repeating: 0.1, count: 48_000), capturedSampleCount: 48_000) }
        preview.start(source: source, recognize: { try await recognizer.run($0) }, update: { texts.append("old: \($0)") })
        await settle()
        await cadence.release()
        await settle()
        #expect(await recognizer.counts.count == 1)
        preview.stop()
        preview.start(source: source, recognize: { try await recognizer.run($0) }, update: { texts.append("new: \($0)") })
        await settle()
        #expect(await recognizer.counts.count == 1)
        await inference.release()
        await settle()
        #expect(texts.isEmpty)
        await cadence.release()
        await settle()
        await inference.release()
        await settle()
        #expect(texts == ["new: These are provisional words."])
        #expect(await recognizer.maximumConcurrent == 1)
        preview.stop()
        await cadence.release()
        await settle()
    }
    @Test func failureEndsPreviewWithoutAutomaticRetry() async {
        let cadence = PreviewGate()
        let preview = LivePreviewSession(pause: { await cadence.wait() })
        var calls = 0
        var texts: [String] = []
        preview.start(
            source: { maximum in
                calls += 1
                return PreviewAudio(samples: Array(repeating: 0.1, count: maximum), capturedSampleCount: maximum)
            }, recognize: { _ in throw CocoaError(.fileReadUnknown) }, update: { texts.append($0) })
        await settle()
        await cadence.release()
        await settle()
        await cadence.release()
        await settle()
        #expect(calls == 1)
        #expect(texts.isEmpty)
        preview.stop()
    }

    @Test func provisionalDisplayIsBoundedByGraphemes() async {
        let cadence = PreviewGate()
        let preview = LivePreviewSession(pause: { await cadence.wait() })
        let source = String(repeating: "👨‍👩‍👧‍👦", count: 400)
        var visible = ""
        preview.start(source: { maximum in PreviewAudio(samples: Array(repeating: 0.1, count: maximum), capturedSampleCount: maximum) }, recognize: { _ in source }, update: { visible = $0 })
        await settle()
        await cadence.release()
        await settle()
        #expect(visible.count == 160)
        #expect(visible == String(source.suffix(160)))
        preview.stop()
        await cadence.release()
        await settle()
    }

    @Test func cadenceAndAttemptBudgetNeverRestartAnExpiredSession() async {
        let preview = LivePreviewSession(pause: {})
        var snapshots = 0
        var inferences = 0
        preview.start(
            source: { _ in
                snapshots += 1
                return PreviewAudio(samples: [], capturedSampleCount: 0)
            }, recognize: { _ in "" }, update: { _ in inferences += 1 })
        for _ in 0..<2_000 where snapshots < 600 { await Task.yield() }
        await settle()
        #expect(snapshots == 600)
        #expect(inferences == 0)
        await settle()
        #expect(snapshots == 600)
        preview.stop()
    }

}
