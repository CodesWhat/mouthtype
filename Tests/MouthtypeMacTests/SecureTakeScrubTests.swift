import Foundation
import MouthtypeCore
import Testing

@testable import MouthtypeMac

@MainActor
private final class WordsEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(
            text: "hunter two secret", words: [WordTiming(word: "hunter", start: 0.1, end: 0.4, confidence: 0.9)],
            processingSeconds: 0, engineID: "stub")
    }
}

@Suite @MainActor struct SecureTakeScrubTests {
    private struct Rig {
        let directory: URL
        let store: TranscriptStore
        let archive: AudioArchive
        let pipeline: DictationPipeline
        let session: DictationSession
    }

    private func rig(secureTarget: Bool) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-secure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try TranscriptStore(url: directory.appendingPathComponent("mouthtype.sqlite"))
        let archive = AudioArchive(supportDirectory: directory)
        let clock = SystemDictationClock()
        let pipeline = DictationPipeline(
            store: TranscriptStoreWriter(store: store), archive: archive, engine: WordsEngine(), clock: clock)
        let session = DictationSession(id: UUID().uuidString, startedAt: clock.now(), keyDownAt: clock.nowNanos())
        return Rig(directory: directory, store: store, archive: archive, pipeline: pipeline, session: session)
    }

    private func run(_ rig: Rig, secureTarget: Bool, result: DeliveryResult) async throws -> CleanedDictation {
        var session = rig.session
        session.rowOpen = await rig.pipeline.begin(session, target: DictationTarget(appName: "Safari", isSecure: secureTarget ? true : nil))
        #expect(session.rowOpen)
        let samples = (0..<16_000).map { Float(0.3 * sin(Double($0) * 0.05)) }
        let audio = CapturedAudio(
            samples: samples, sampleRate: 16000, deviceUID: nil, deviceName: nil, deviceTransport: "test",
            firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 1000)
        let features = await rig.pipeline.recordCapture(audio, session: session, keyUpMs: 1000)
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: session.id).path))
        let transcribed = try #require(
            try await rig.pipeline.transcribe(audio, session: session, voicedMs: features.voicedMs))
        let cleaned = CleanedDictation(
            text: "Hunter two secret.", edits: [EditOp(stage: "cleanup", kind: .replace, fromText: transcribed.text, toText: "Hunter two secret.", wordDelta: 0, position: 0)],
            cleanup: CleanupRecord(cleanerID: "deterministic"), deterministicText: "Hunter two secret.")
        var delivered = result
        delivered.finalText = result.outcome == .secureDiscard ? "" : result.finalText
        await rig.pipeline.recordInsertion(delivered, session: session, cleaned: cleaned)
        return cleaned
    }

    @Test func aSecureFieldTakeLeavesNoTextTimingsSearchHitOrAudio() async throws {
        let rig = try rig(secureTarget: true)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        _ = try await run(rig, secureTarget: true, result: result)

        let row = try #require(try rig.store.dictation(id: rig.session.id))
        #expect(row.rawText == nil && row.detText == nil && row.finalText == nil && row.wordTimingsJson == nil)
        #expect(row.isSecure == true)
        #expect(row.insertOutcome == "secure discard")
        #expect(try rig.store.editOps(id: rig.session.id).isEmpty)
        #expect(try rig.store.recentTakes(limit: 10).isEmpty)
        #expect(try rig.store.recentTakes(limit: 10, query: "hunter").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.archive.url(for: rig.session.id).path))
        #expect(!FileManager.default.fileExists(atPath: rig.archive.partialURL(for: rig.session.id).path))
        // The pointer waits for the sweep, which clears it once the file is confirmed gone.
        _ = try AudioRetentionMaintenance.prune(archive: rig.archive, store: rig.store, policy: .init(), now: Date())
        #expect(try rig.store.dictation(id: rig.session.id)?.audioPath == nil)
    }

    @Test func theSecureRefusalAndScrubLandInOneWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-secure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(url: directory.appendingPathComponent("s.sqlite"))
        try store.begin(DictationStart(id: "one", target: DictationTarget(isSecure: true)))
        try store.recordTranscription(
            "one",
            TranscriptionRecord(
                transcription: Transcription(text: "hunter", words: [WordTiming(word: "hunter", start: 0, end: 0.3, confidence: 1)], processingSeconds: 0, engineID: "t"),
                rawText: "hunter"))
        try store.appendEdits("one", [EditOp(stage: "cleanup", kind: .replace, fromText: "hunter", toText: "Hunter", wordDelta: 0, position: 0)])
        try store.recordCapture("one", CaptureRecord(audioPath: "/tmp/elsewhere/one.wav"))
        try store.finishSecureTake("one", InsertionRecord(finalText: "", method: "none", outcome: "secure discard"))
        let row = try #require(try store.dictation(id: "one"))
        #expect(row.status == .inserted && row.isSecure == true)
        #expect(row.rawText == nil && row.detText == nil && row.finalText == nil && row.wordTimingsJson == nil)
        #expect(try store.editOps(id: "one").isEmpty)
        #expect(row.audioPath == "/tmp/elsewhere/one.wav")
    }

    @Test func aTakeBlockedOnlyBySecureInputIsKeptAndShowsInHome() async throws {
        let rig = try rig(secureTarget: false)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        var result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        result.secureInputBlocked = true
        _ = try await run(rig, secureTarget: false, result: result)

        let row = try #require(try rig.store.dictation(id: rig.session.id))
        #expect(row.isSecure != true)
        #expect(row.finalText == "Hunter two secret.")
        #expect(row.insertOutcome == "not landed" && row.insertMethod == "none")
        #expect(row.rawText == "hunter two secret")
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: rig.session.id).path))
        let takes = try rig.store.recentTakes(limit: 10)
        #expect(takes.map(\.finalText) == ["Hunter two secret."])
        #expect(try rig.store.recentTakes(limit: 10, query: "hunter").count == 1)
    }

    @Test func recoveryDoesNotOfferAnUnfinishedSecureTakeAndScrubsIt() throws {
        let rig = try rig(secureTarget: true)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try rig.store.begin(
            DictationStart(
                id: "cut-off", startedAt: Date(timeIntervalSinceNow: -60), mode: .hold, trigger: .fn,
                target: DictationTarget(isSecure: true), appVersion: "t", osVersion: "t"))
        try rig.archive.appendPartial(samples: [Float](repeating: 0.2, count: 4000), id: "cut-off")
        try rig.store.recordTranscription(
            "cut-off",
            TranscriptionRecord(
                transcription: Transcription(text: "my password", words: [], processingSeconds: 0.1, engineID: "t"),
                rawText: "my password"))
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: Date(), launchedAt: Date())
        #expect(scan.newest == nil && scan.olderCount == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.archive.partialURL(for: "cut-off").path))
        let row = try #require(try rig.store.dictation(id: "cut-off"))
        #expect(row.isSecure == true)
        #expect(row.status == .failed)
        #expect(row.rawText == nil && row.detText == nil && row.finalText == nil)
        #expect(try rig.store.recentTakes(limit: 10, query: "password").isEmpty)
        #expect(try DictationRecovery.saved(store: rig.store, archive: rig.archive, now: Date(), launchedAt: Date()).isEmpty)
    }
}
