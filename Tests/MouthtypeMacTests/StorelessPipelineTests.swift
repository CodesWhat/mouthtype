import Foundation
import MouthtypeCore
import Testing

@testable import MouthtypeMac

private final class SpyArchive: DictationArchiving, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    var ids: [String] { lock.withLock { written } }
    func archive(samples: [Float], id: String) throws -> URL {
        lock.withLock { written.append(id) }
        return URL(fileURLWithPath: "/dev/null/\(id).wav")
    }
}

@MainActor
private final class StubEngine: DictationEngine {
    let text: String
    init(text: String) { self.text = text }
    var readiness: EngineReadiness { .ready }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: text, processingSeconds: 0, engineID: "stub")
    }
}

@Suite @MainActor struct StorelessPipelineTests {
    private func capture() -> CapturedAudio {
        CapturedAudio(
            samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, deviceUID: nil, deviceName: nil,
            deviceTransport: "test", firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 100)
    }

    @Test func withoutAStoreNoWavIsWritten() async {
        let archive = SpyArchive()
        let clock = SystemDictationClock()
        let pipeline = DictationPipeline(store: nil, archive: archive, engine: StubEngine(text: "hi"), clock: clock)
        let session = DictationSession(id: "orphan", startedAt: clock.now(), keyDownAt: clock.nowNanos())
        let result = await pipeline.recordCaptureAndArchive(capture(), session: session, keyUpMs: 10)
        #expect(archive.ids.isEmpty)
        #expect(!result.durable)
    }

    @Test func withAStoreTheWavIsStillWritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-storeless-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        let archive = SpyArchive()
        let clock = SystemDictationClock()
        let pipeline = DictationPipeline(
            store: TranscriptStoreWriter(store: store), archive: archive, engine: StubEngine(text: "hi"), clock: clock)
        let session = DictationSession(id: "kept", startedAt: clock.now(), keyDownAt: clock.nowNanos())
        _ = await pipeline.recordCaptureAndArchive(capture(), session: session, keyUpMs: 10)
        #expect(archive.ids == ["kept"])
    }
}
