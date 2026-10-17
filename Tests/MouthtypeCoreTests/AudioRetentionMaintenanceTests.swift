import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioRetentionMaintenanceTests {
    @Test func pruningCompletedAudioClearsOnlyDeletedPointersAndKeepsTextAndTimings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for (id, days) in [("old", 30.0), ("recent", 1.0)] {
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-days * 86_400)))
            let audio = try archive.write(samples: [0.1, 0.2], id: id)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: audio.url.path)
            try store.recordCapture(id, CaptureRecord(audioPath: audio.url.path, audioExpiresAt: now))
            try store.recordTranscription(id, TranscriptionRecord(transcription: Transcription(text: "Keep café.", words: [WordTiming(word: "Keep", start: 0, end: 0.4, confidence: 1)], processingSeconds: 0.1, engineID: "fake"), rawText: "Keep café."))
            try store.recordInsertion(id, InsertionRecord(finalText: "Keep café."))
        }
        let before = try #require(try store.dictation(id: "old"))
        let removed = try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        #expect(removed == ["old"])
        let after = try #require(try store.dictation(id: "old"))
        #expect(after.audioPath == nil && after.audioExpiresAt == nil)
        #expect(after.rawText == before.rawText && after.finalText == before.finalText && after.wordTimingsJson == before.wordTimingsJson)
        #expect(after.status == before.status && after.wordsFinal == before.wordsFinal)
        #expect(try store.dictation(id: "recent")?.audioPath != nil)
        #expect(FileManager.default.fileExists(atPath: archive.url(for: "recent").path))
    }

    @Test(arguments: [false, true])
    func unfinishedAndFailedRecoveryAudioSurvivesMaintenanceBeforeOrAfterStartupScan(scanFirst: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for (id, status) in [("unfinished", DictationStatus.recorded), ("failed", .failed)] {
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-60)))
            let audio = try archive.write(samples: [0.1, 0.2], id: id)
            try store.recordCapture(id, CaptureRecord(audioPath: audio.url.path))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120 * 86_400)], ofItemAtPath: audio.url.path)
            if status == .failed { try store.finish(id, status: .failed) }
        }
        if scanFirst { _ = try DictationRecovery.scan(store: store, archive: archive, now: now, launchedAt: now) }
        let removed = try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        #expect(removed.isEmpty)
        for id in ["unfinished", "failed"] {
            #expect(FileManager.default.fileExists(atPath: archive.url(for: id).path))
            #expect(try store.dictation(id: id)?.audioPath != nil)
        }
    }
}
