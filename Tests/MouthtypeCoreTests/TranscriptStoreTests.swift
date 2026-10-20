import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct TranscriptStoreTests {
    @Test func lastTranscriptSkipsEmptyAndSecureRowsEvenAfterManyAttempts() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.lastTranscript() == nil)
        let first = try store.begin(DictationStart(startedAt: Self.noon))
        try store.recordInsertion(first, InsertionRecord(finalText: "Keep this text"))
        for n in 1...30 {
            let id = try store.begin(DictationStart(startedAt: Self.noon.addingTimeInterval(Double(n))))
            try store.recordInsertion(id, InsertionRecord(finalText: n == 30 ? "private" : "", target: DictationTarget(isSecure: true)))
        }
        #expect(try store.lastTranscript() == "Keep this text")
    }

    @Test func recentTakesFiltersInSqlAndHonoursTheLimit() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 0..<8 {
            let id = try store.begin(DictationStart(startedAt: Self.noon.addingTimeInterval(Double(n))))
            let text = n == 7 ? "   " : "take \(n)"
            try store.recordInsertion(id, InsertionRecord(finalText: text, target: DictationTarget(isSecure: n == 6 ? true : nil)))
        }
        let takes = try store.recentTakes(limit: 3)
        #expect(takes.map(\.finalText) == ["take 5", "take 4", "take 3"])
    }

    private static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-12 12:00:00 UTC
    private static let noon = Date(timeIntervalSince1970: 1_791_806_400)

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("nested/mouthtype.sqlite")
        return (try TranscriptStore(url: url), dir)
    }

    private func start(_ store: TranscriptStore, at date: Date = noon, zone: TimeZone = utc) throws -> String {
        try store.begin(DictationStart(startedAt: date, timeZone: zone))
    }

    /// Inserts a finished dictation with the given numbers.
    @discardableResult
    private func dictate(
        _ store: TranscriptStore, at date: Date, words: Int, audioMs: Int?, voicedMs: Int? = nil
    ) throws -> String {
        let id = try start(store, at: date)
        try store.recordCapture(id, CaptureRecord(audioMs: audioMs, voicedMs: voicedMs))
        try store.recordInsertion(id, InsertionRecord(finalText: Array(repeating: "word", count: words).joined(separator: " ")))
        return id
    }

    @Test func migrationCreatesTheSchema() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("nested/mouthtype.sqlite").path)
        let (tables, indexes, columns, migrations) = try pool.read { db in
            (
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"),
                try db.columns(in: "dictation").map(\.name),
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            )
        }
        #expect(tables.contains("dictation") && tables.contains("edit_op"))
        #expect(indexes.contains("dictation_local_day") && indexes.contains("dictation_started_at") && indexes.contains("dictation_status"))
        #expect(migrations == ["v1", "v2"])
        #expect(tables.contains("correction"))
        for column in ["id", "started_at", "utc_offset_s", "local_day", "first_nonzero_ms", "word_timings_json", "raw_text",
                       "det_text", "final_text", "prompt_sha", "is_secure", "paste_receipt_ms", "retry_of", "os_version", "error_message"] {
            #expect(columns.contains(column), "missing \(column)")
        }
        #expect(!columns.contains { $0.contains("field") && $0.contains("text") })
        _ = store
    }

    @Test func v2AddsTheCorrectionTableWithoutLosingV1Rows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        let pool = try DatabasePool(path: url.path)
        try TranscriptStore.migrator.migrate(pool, upTo: "v1")
        try pool.write { db in
            for n in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, final_text)
                    VALUES (?, 1, 0, '2026-10-12', 'hold', 'fn', 'inserted', ?)
                    """, arguments: ["old-\(n)", "text \(n)"])
            }
            #expect(try !db.tableExists("correction"))
        }
        try pool.close()

        let store = try TranscriptStore(url: url)
        #expect(try store.recent(limit: 10).count == 3)
        #expect(try store.dictation(id: "old-1")?.finalText == "text 1")
        let id = try store.recordCorrectionOffer(dictationID: "old-1", heard: "Hove", corrected: "Hov")
        #expect(try store.corrections(dictationID: "old-1").count == 1 && id > 0)
    }

    @Test func correctionOffersAndOutcomesAreRecordedAndTheDictationTextIsUntouched() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try dictate(store, at: Self.noon, words: 4, audioMs: 1000)
        let before = try #require(try store.dictation(id: id))
        let first = try store.recordCorrectionOffer(dictationID: id, heard: "Hove", corrected: "Hov", at: Self.noon)
        let second = try store.recordCorrectionOffer(dictationID: id, kind: .forget, heard: "hove", corrected: "Hov", at: Self.noon)
        var rows = try store.corrections(dictationID: id)
        #expect(rows.map(\.accepted) == [nil, nil] && rows.map(\.kind) == [.remember, .forget])
        #expect(rows[0].heard == "Hove" && rows[0].corrected == "Hov" && rows[0].createdAt == Self.noon.timeIntervalSince1970)
        try store.recordCorrectionOutcome(first, accepted: true)
        try store.recordCorrectionOutcome(second, accepted: false)
        rows = try store.corrections(dictationID: id)
        #expect(rows.map(\.accepted) == [true, false])
        #expect(try store.dictation(id: id) == before)
    }

    @Test func correctionsFollowTheirDictationAndNeedOne() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try store.recordCorrectionOffer(dictationID: "missing", heard: "a", corrected: "b") }
        let id = try dictate(store, at: Self.noon, words: 4, audioMs: 1000)
        try store.recordCorrectionOffer(dictationID: id, heard: "a", corrected: "b")
        try store.delete(id)
        #expect(try store.corrections(dictationID: id).isEmpty)
    }

    @Test func recordLockUpdatesModeAndTriggerOnTheOpenRow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        var row = try #require(try store.dictation(id: id))
        #expect(row.mode == "hold" && row.trigger == "fn")
        try store.recordLock(id, mode: .handsFree, trigger: .doubleTap)
        row = try #require(try store.dictation(id: id))
        #expect(row.mode == "hands_free" && row.trigger == "double_tap")
        try store.recordLock(id, mode: .handsFree, trigger: .fnSpace)
        #expect(try store.dictation(id: id)?.trigger == "fn_space")
        #expect(throws: TranscriptStoreError.self) { try store.recordLock("missing", mode: .handsFree, trigger: .fnSpace) }
    }

    @Test func reopeningRunsNoMigrationTwice() throws {
        let (_, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try TranscriptStore(url: dir.appendingPathComponent("nested/mouthtype.sqlite"))
    }

    @Test func stagedLifecycleRoundTrips() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aest = try #require(TimeZone(identifier: "Australia/Sydney"))
        let id = try store.begin(DictationStart(
            startedAt: Self.noon, timeZone: aest, mode: .hold, trigger: .fn,
            target: DictationTarget(bundleID: "com.apple.Notes", appName: "Notes", isSecure: false),
            appVersion: "0.1.0", osVersion: "26.0"
        ))
        var row = try #require(try store.dictation(id: id))
        #expect(row.status == .started)
        #expect(row.localDay == "2026-10-12")
        #expect(row.utcOffsetS == 39_600)
        #expect(row.appBundleId == "com.apple.Notes" && row.isSecure == false)
        #expect(row.startedAt == Self.noon.timeIntervalSince1970)

        try store.recordCapture(id, CaptureRecord(
            captureStartMs: 12, firstSampleMs: 30, firstNonzeroMs: 45, keyUpMs: 2_100, audioMs: 2_000, voicedMs: 1_400,
            audioPath: "/x/audio/\(id).wav", inputDeviceUID: "uid", inputDeviceName: "MacBook Mic", inputTransport: "built-in",
            sampleRateHz: 16_000, rmsDb: -30, peakDb: -6, noiseFloorDb: -60
        ))
        row = try #require(try store.dictation(id: id))
        #expect(row.status == .recorded)
        #expect(row.firstNonzeroMs == 45 && row.audioMs == 2_000 && row.noiseFloorDb == -60)

        let words = [WordTiming(word: "hello", start: 0.1, end: 0.4, confidence: 0.9), WordTiming(word: "world", start: 0.5, end: 0.9, confidence: 0.8)]
        try store.recordTranscription(id, TranscriptionRecord(
            transcription: Transcription(text: "hello world", words: words, confidence: 0.85, processingSeconds: 0.25, engineID: "parakeet-tdt-v3", modelRevision: "rev1"),
            rawText: "hello  world um", asrDoneMs: 2_400, language: "en", boostTerms: ["Mouthtype"]
        ))
        row = try #require(try store.dictation(id: id))
        #expect(row.status == .transcribed)
        #expect(row.asrEngineId == "parakeet-tdt-v3" && row.asrModelRev == "rev1" && row.asrMs == 250)
        #expect(row.wordsRaw == 3 && row.rawText == "hello  world um")
        #expect(try row.wordTimings() == words)
        #expect(row.boostTermsAppliedJson == "[\"Mouthtype\"]")

        try store.recordInsertion(id, InsertionRecord(
            finalText: "Hello world.", cleanup: CleanupRecord(cleanerID: "apple", ms: 80, outcome: "ok", doneMs: 2_500),
            method: "paste", outcome: "confirmed", focusMoved: false, insertDoneMs: 2_600
        ))
        row = try #require(try store.dictation(id: id))
        #expect(row.status == .inserted)
        #expect(row.finalText == "Hello world." && row.wordsFinal == 2 && row.charsFinal == 12)
        #expect(row.cleanerId == "apple" && row.cleanupOutcome == "ok" && row.insertMethod == "paste" && row.insertDoneMs == 2_600)
        #expect(row.rawText == "hello  world um")

        #expect(try store.recent(limit: 5).map(\.id) == [id])
    }

    @Test func aCancelledRowReopensAndThenCompletes() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        try store.finish(id, status: .cancelled)
        try store.reopen(id)
        #expect(try store.dictation(id: id)?.status == .started)
        try store.recordInsertion(id, InsertionRecord(finalText: "Hello again."))
        #expect(try store.dictation(id: id)?.status == .inserted)
        #expect(try store.dictation(id: id)?.finalText == "Hello again.")
    }

    @Test func aVerdictSettlesTheOutcomeAndTheReceiptAfterTheFact() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        try store.recordInsertion(id, InsertionRecord(finalText: "Hello.", method: "paste", outcome: "unknown", insertDoneMs: 900))
        try store.recordInsertVerdict(id, outcome: "not landed")
        var row = try #require(try store.dictation(id: id))
        #expect(row.insertOutcome == "not landed" && row.pasteReceiptMs == nil && row.finalText == "Hello.")
        try store.recordInsertVerdict(id, outcome: "confirmed", pasteReceiptMs: 41)
        row = try #require(try store.dictation(id: id))
        #expect(row.insertOutcome == "confirmed" && row.pasteReceiptMs == 41 && row.insertDoneMs == 900)
        try store.recordInsertVerdict(id, outcome: "unknown")
        #expect(try store.dictation(id: id)?.pasteReceiptMs == 41)
        #expect(throws: TranscriptStoreError.unknownDictation("nope")) { try store.recordInsertVerdict("nope", outcome: "unknown") }
    }

    @Test func onlyACancelledRowReopens() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        #expect(throws: TranscriptStoreError.notCancelled(.started)) { try store.reopen(id) }
        try store.finish(id, status: .empty)
        #expect(throws: TranscriptStoreError.notCancelled(.empty)) { try store.reopen(id) }
        #expect(throws: TranscriptStoreError.unknownDictation("nope")) { try store.reopen("nope") }
    }

    @Test func cancelledAttemptIsARow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancelled = try start(store)
        try store.finish(cancelled, status: .cancelled)
        let failed = try start(store)
        try store.finish(failed, status: .failed, errorMessage: "engine not ready")

        #expect(try store.dictation(id: cancelled)?.status == .cancelled)
        let row = try #require(try store.dictation(id: failed))
        #expect(row.status == .failed && row.errorMessage == "engine not ready")
        #expect(try store.recent(limit: 10).isEmpty)
        #expect(throws: TranscriptStoreError.notTerminal(.inserted)) { try store.finish(cancelled, status: .inserted) }
        #expect(throws: TranscriptStoreError.unknownDictation("nope")) { try store.finish("nope", status: .empty) }
    }

    @Test func editOpsCascadeOnDelete() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        let edits = [
            EditOp(stage: "filler", kind: .delete, fromText: "um", wordDelta: -1, position: 1),
            EditOp(stage: "llm", kind: .replace, fromText: "teh", toText: "the", wordDelta: 0, position: 4),
        ]
        try store.appendEdits(id, edits)
        #expect(try store.editOps(id: id) == edits)

        try store.delete(id)
        #expect(try store.dictation(id: id) == nil)
        #expect(try store.editOps(id: id).isEmpty)
        #expect(throws: TranscriptStoreError.unknownDictation(id)) { try store.appendEdits(id, edits) }
    }

    @Test func clearAudioNullsThePath() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try start(store)
        try store.recordCapture(id, CaptureRecord(audioPath: "/x.wav", audioExpiresAt: Self.noon))
        try store.clearAudio(ids: [id])
        let row = try #require(try store.dictation(id: id))
        #expect(row.audioPath == nil && row.audioExpiresAt == nil)
    }

    // MARK: Stats

    @Test func wordsTodayUsesTheInjectedDay() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, at: Self.noon, words: 10, audioMs: 5_000)
        try dictate(store, at: Self.noon.addingTimeInterval(60), words: 5, audioMs: 5_000)
        try dictate(store, at: Self.noon.addingTimeInterval(-86_400), words: 100, audioMs: 5_000)

        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).wordsToday == 15)
        #expect(try store.stats(now: Self.noon.addingTimeInterval(86_400), timeZone: Self.utc).wordsToday == 0)
        #expect(try store.stats(now: Self.noon.addingTimeInterval(-86_400), timeZone: Self.utc).wordsToday == 100)
    }

    @Test func wpmUsesVoicedTimeThenAudioTime() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, at: Self.noon, words: 60, audioMs: 30_000, voicedMs: 20_000)
        try dictate(store, at: Self.noon.addingTimeInterval(10), words: 40, audioMs: 10_000)   // no voiced: audio fallback
        // 100 words over 30 s.
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).recentWPM == 200)
    }

    @Test func wpmSkipsZeroWordsAndLongAudioAndCapsAtOneHundred() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).recentWPM == 0)

        try dictate(store, at: Self.noon, words: 500, audioMs: 400_000)            // too long, excluded
        let silent = try start(store, at: Self.noon.addingTimeInterval(1))          // never inserted, excluded
        try store.recordCapture(silent, CaptureRecord(audioMs: 3_000))
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).recentWPM == 0)

        // 100 recent dictations at 60 wpm (1 word per second), plus an older fast one that falls outside the window.
        try dictate(store, at: Self.noon.addingTimeInterval(-10_000), words: 1_000, audioMs: 1_000)
        for i in 0..<100 {
            try dictate(store, at: Self.noon.addingTimeInterval(Double(10 + i)), words: 2, audioMs: 2_000)
        }
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).recentWPM == 60)
    }

    @Test func streaksComeFromLocalDaysWithWords() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for back in [0.0, 1, 2, 5, 6, 7, 8] {
            try dictate(store, at: Self.noon.addingTimeInterval(-back * 86_400), words: 3, audioMs: 1_000)
        }
        // A day with only a cancelled attempt does not count.
        let cancelled = try start(store, at: Self.noon.addingTimeInterval(-3 * 86_400))
        try store.finish(cancelled, status: .cancelled)

        let stats = try store.stats(now: Self.noon, timeZone: Self.utc)
        #expect(stats.currentStreakDays == 3)
        #expect(stats.longestStreakDays == 4)
    }

    @Test func transcriptionRecordsSpeechOnsetAndInsertionRecordsTheDeliveryTarget() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.begin(DictationStart(
            startedAt: Self.noon, timeZone: Self.utc, target: DictationTarget(bundleID: "com.apple.Notes", appName: "Notes")
        ))
        try store.recordTranscription(id, TranscriptionRecord(
            transcription: Transcription(text: "hi", processingSeconds: 0.1, engineID: "e"), rawText: "hi", speechOnsetMs: 420
        ))
        #expect(try store.dictation(id: id)?.speechOnsetMs == 420)

        try store.recordInsertion(id, InsertionRecord(finalText: "hi", target: DictationTarget(bundleID: "com.apple.mail", appName: "Mail", isSecure: false)))
        let row = try #require(try store.dictation(id: id))
        #expect(row.appBundleId == "com.apple.mail" && row.appName == "Mail" && row.isSecure == false)

        try store.recordInsertion(id, InsertionRecord(finalText: "hi"))
        #expect(try store.dictation(id: id)?.appBundleId == "com.apple.mail")
    }

    @Test func aStaleStartedRowFromACrashDoesNotAffectRecentStatsOrTheNextDictation() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = try start(store, at: Self.noon.addingTimeInterval(-60))
        #expect(try store.recent(limit: 10).isEmpty)
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc) == StatsSummary(
            wordsToday: 0, recentWPM: 0, currentStreakDays: 0, longestStreakDays: 0
        ))

        let next = try dictate(store, at: Self.noon, words: 3, audioMs: 3_000)
        #expect(try store.recent(limit: 10).map(\.id) == [next])
        #expect(try store.stats(now: Self.noon, timeZone: Self.utc).wordsToday == 3)
        #expect(try store.dictation(id: stale)?.status == .started)
    }
}
