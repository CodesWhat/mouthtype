import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioRetentionMaintenanceTests {
    @Test func completedSnapshotExcludesNewTakesAndUnknownWavsAfterClockRollback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        let policy = AudioRetentionPolicy()
        for index in 0..<64 {
            let id = "completed-\(index)"
            try store.begin(DictationStart(id: id))
            let entry = try archive.write(samples: [0.1, 0.2], id: id)
            let handle = try FileHandle(forWritingTo: entry.url)
            try handle.truncate(atOffset: UInt64(policy.maximumBytes / 64))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(86_400)], ofItemAtPath: entry.url.path)
            try store.recordCapture(id, CaptureRecord(audioPath: entry.url.path))
            try store.recordInsertion(id, InsertionRecord(finalText: "Completed."))
        }
        let completed = try store.audioRetentionCandidateIDs()
        #expect(completed.count == 64)
        try store.begin(DictationStart(id: "new-take"))
        let active = try archive.write(samples: [0.1, 0.2], id: "new-take")
        try store.recordCapture("new-take", CaptureRecord(audioPath: active.url.path))
        let unknown = try archive.write(samples: [0.1, 0.2], id: "unknown")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-365 * 86_400)], ofItemAtPath: unknown.url.path)
        let removed = try archive.purge(olderThan: policy.cutoff(at: now), maxTotalBytes: policy.maximumBytes, eligibleIDs: completed)
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: active.url.path))
        #expect(FileManager.default.fileExists(atPath: unknown.url.path))
        #expect(try store.dictation(id: "new-take")?.status == .recorded)
        #expect(try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: policy, now: now).isEmpty)
        #expect(try store.dictation(id: "new-take")?.audioPath == active.url.path)
    }

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
            try store.recordTranscription(
                id,
                TranscriptionRecord(
                    transcription: Transcription(text: "Keep café.", words: [WordTiming(word: "Keep", start: 0, end: 0.4, confidence: 1)], processingSeconds: 0.1, engineID: "fake"),
                    rawText: "Keep café."))
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

    @Test func aFailedRemovalStillClearsPointersForFilesAlreadyDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        var urls: [String: URL] = [:]
        for id in ["a", "b", "c"] {
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-30 * 86_400)))
            let audio = try archive.write(samples: [0.1, 0.2], id: id)
            urls[id] = audio.url
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: audio.url.path)
            try store.recordCapture(id, CaptureRecord(audioPath: audio.url.path, audioExpiresAt: now))
            try store.recordInsertion(id, InsertionRecord(finalText: "Done."))
        }
        let blocked = try #require(urls["b"])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let removed = try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        #expect(Set(removed) == ["a", "c"])
        #expect(try store.dictation(id: "a")?.audioPath == nil)
        #expect(try store.dictation(id: "c")?.audioPath == nil)
        #expect(try store.dictation(id: "b")?.audioPath == blocked.path)
        #expect(FileManager.default.fileExists(atPath: blocked.path))
    }

    @Test(arguments: [false, true])
    func recentUnfinishedAndFailedAudioSurvivesAndExpiredIsRemovedBeforeOrAfterStartupScan(scanFirst: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        // Under a 14-day setting, a take inside the recovery grace survives and one past it goes.
        let cases: [(id: String, status: DictationStatus, age: Double)] = [
            ("unfinished-recent", .recorded, 20), ("failed-recent", .failed, 20),
            ("unfinished-old", .recorded, 120), ("failed-old", .failed, 120),
        ]
        for (id, status, age) in cases {
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-60)))
            let audio = try archive.write(samples: [0.1, 0.2], id: id)
            try store.recordCapture(id, CaptureRecord(audioPath: audio.url.path))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: audio.url.path)
            if status == .failed { try store.finish(id, status: .failed) }
        }
        if scanFirst { _ = try DictationRecovery.scan(store: store, archive: archive, now: now, launchedAt: now) }
        let removed = try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        #expect(Set(removed) == ["unfinished-old", "failed-old"])
        for id in ["unfinished-recent", "failed-recent"] {
            #expect(FileManager.default.fileExists(atPath: archive.url(for: id).path))
            #expect(try store.dictation(id: id)?.audioPath != nil)
        }
        for id in ["unfinished-old", "failed-old"] {
            #expect(!FileManager.default.fileExists(atPath: archive.url(for: id).path))
            #expect(try store.dictation(id: id)?.audioPath == nil)
        }
    }

    @Test func partialsSurviveInsideTheRecoveryGraceAndGoAfterIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for (id, age) in [("fresh", 2.0), ("stale", 120.0)] {
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-age * 86_400)))
            try archive.appendPartial(samples: [0.1, 0.2], id: id)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: archive.partialURL(for: id).path)
        }
        try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        #expect(FileManager.default.fileExists(atPath: archive.partialURL(for: "fresh").path))
        #expect(!FileManager.default.fileExists(atPath: archive.partialURL(for: "stale").path))
    }

    @Test func deletingATakeWithTheArchiveRemovesItsAudioAndPartial() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        try store.begin(DictationStart(id: "gone"))
        let audio = try archive.write(samples: [0.1, 0.2], id: "gone")
        try archive.appendPartial(samples: [0.1], id: "gone")
        try store.recordCapture("gone", CaptureRecord(audioPath: audio.url.path))
        try store.delete("gone", archive: archive)
        #expect(!FileManager.default.fileExists(atPath: archive.url(for: "gone").path))
        #expect(!FileManager.default.fileExists(atPath: archive.partialURL(for: "gone").path))
    }

    @Test func pruneNeverRemovesAudioThatHasNoRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        var urls: [URL] = []
        for id in ["a", "b"] { urls.append(try archive.write(samples: [0.1, 0.2], id: id).url) }
        // An emptied or restored database has no rows for any of it.
        for url in urls { try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-400 * 86_400)], ofItemAtPath: url.path) }
        try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        for url in urls { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func prunePutsStalePartialsThroughTheRetentionPolicy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        try store.begin(DictationStart(id: "p", startedAt: now.addingTimeInterval(-120 * 86_400)))
        try archive.appendPartial(samples: [0.1, 0.2], id: "p")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120 * 86_400)], ofItemAtPath: archive.partialURL(for: "p").path)
        try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .noAgeLimit), now: now)
        #expect(FileManager.default.fileExists(atPath: archive.partialURL(for: "p").path))
    }

    @Test func pruneLeavesPointersAloneWhenTheArchiveDirectoryIsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        try store.begin(DictationStart(id: "x"))
        try store.recordCapture("x", CaptureRecord(audioPath: archive.url(for: "x").path))
        try store.recordInsertion("x", InsertionRecord(finalText: "Hi."))
        #expect(archive.listedFileNames() == nil)
        try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: Date())
        #expect(try store.dictation(id: "x")?.audioPath != nil)
    }

    @Test func pruneClearsPointersWhoseFileIsMissingButKeepsRelocatedOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("store.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        try store.begin(DictationStart(id: "lost"))
        let lost = try archive.write(samples: [0.1, 0.2], id: "lost")
        try store.recordCapture("lost", CaptureRecord(audioPath: lost.url.path, audioExpiresAt: now))
        try store.recordInsertion("lost", InsertionRecord(finalText: "Hi."))
        try FileManager.default.removeItem(at: lost.url)  // a crash after the delete, before the pointer was cleared
        try store.begin(DictationStart(id: "moved"))
        _ = try archive.write(samples: [0.1, 0.2], id: "moved")
        try store.recordCapture("moved", CaptureRecord(audioPath: "/Users/old-name/audio/moved.wav"))
        try store.recordInsertion("moved", InsertionRecord(finalText: "Hi."))
        try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: AudioRetentionPolicy(age: .days14), now: now)
        let row = try #require(try store.dictation(id: "lost"))
        #expect(row.audioPath == nil && row.audioExpiresAt == nil && row.finalText == "Hi.")
        #expect(try store.dictation(id: "moved")?.audioPath != nil)
    }
}
