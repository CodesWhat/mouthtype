import Foundation
import GRDB

public enum TranscriptStoreError: Error, Equatable {
    case unknownDictation(String)
    case notTerminal(DictationStatus)
    case notCancelled(DictationStatus)
}

public final class TranscriptStore: Sendable {
    private let pool: DatabasePool

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mouthtype", isDirectory: true)
            .appendingPathComponent("mouthtype.sqlite")
    }

    public init(url: URL = TranscriptStore.defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        pool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictation (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    utc_offset_s INTEGER NOT NULL,
                    local_day TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error_message TEXT,

                    capture_start_ms INTEGER, first_sample_ms INTEGER, first_nonzero_ms INTEGER,
                    speech_onset_ms INTEGER, key_up_ms INTEGER, asr_done_ms INTEGER,
                    cleanup_done_ms INTEGER, insert_done_ms INTEGER,

                    audio_ms INTEGER, voiced_ms INTEGER, audio_path TEXT, audio_expires_at REAL,
                    input_device_uid TEXT, input_device_name TEXT, input_transport TEXT, sample_rate_hz INTEGER,
                    rms_db REAL, peak_db REAL, noise_floor_db REAL,

                    asr_engine_id TEXT, asr_model_rev TEXT, asr_ms INTEGER, asr_confidence REAL, language TEXT,
                    word_timings_json TEXT, boost_terms_applied_json TEXT,

                    raw_text TEXT, det_text TEXT, final_text TEXT,
                    words_raw INTEGER, words_final INTEGER, chars_final INTEGER,

                    cleaner_id TEXT, cleaner_rev TEXT, cleanup_level TEXT, style TEXT,
                    cleanup_ms INTEGER, cleanup_outcome TEXT, prompt_sha TEXT,

                    app_bundle_id TEXT, app_name TEXT, url_domain TEXT, window_title TEXT,
                    category TEXT, field_role TEXT, is_secure INTEGER,

                    insert_method TEXT, insert_outcome TEXT, focus_moved INTEGER, paste_receipt_ms INTEGER,

                    retry_of TEXT, app_version TEXT, os_version TEXT
                );
                CREATE INDEX dictation_local_day ON dictation(local_day);
                CREATE INDEX dictation_started_at ON dictation(started_at);
                CREATE INDEX dictation_status ON dictation(status);

                CREATE TABLE edit_op (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    dictation_id TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
                    stage TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    from_text TEXT,
                    to_text TEXT,
                    word_delta INTEGER NOT NULL DEFAULT 0,
                    position INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX edit_op_dictation_id ON edit_op(dictation_id);
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE correction (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    dictation_id TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL DEFAULT 'remember',
                    heard TEXT NOT NULL,
                    corrected TEXT NOT NULL,
                    accepted INTEGER,
                    created_at REAL NOT NULL
                );
                CREATE INDEX correction_dictation_id ON correction(dictation_id);
                """)
        }
        return migrator
    }

    // MARK: Staged writes

    /// Inserts the row at key-down. Returns its id.
    @discardableResult
    public func begin(_ start: DictationStart) throws -> String {
        let offset = start.timeZone.secondsFromGMT(for: start.startedAt)
        let target = start.target
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status,
                    app_bundle_id, app_name, url_domain, window_title, category, field_role, is_secure,
                    retry_of, app_version, os_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    start.id, start.startedAt.timeIntervalSince1970, offset,
                    Streaks.localDay(for: start.startedAt, in: start.timeZone),
                    start.mode.rawValue, start.trigger.rawValue, DictationStatus.started,
                    target.bundleID, target.appName, target.urlDomain, target.windowTitle,
                    target.category, target.fieldRole, target.isSecure,
                    start.retryOf, start.appVersion, start.osVersion,
                ])
        }
        return start.id
    }

    /// A hold that became a hands-free recording: the row opened at key-down as hold/fn.
    public func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) throws {
        try update(id, [("mode", mode.rawValue), ("trigger", trigger.rawValue)])
    }

    public func recordCapture(_ id: String, _ capture: CaptureRecord) throws {
        try update(id, [
            ("status", DictationStatus.recorded),
            ("capture_start_ms", capture.captureStartMs), ("first_sample_ms", capture.firstSampleMs),
            ("first_nonzero_ms", capture.firstNonzeroMs), ("speech_onset_ms", capture.speechOnsetMs),
            ("key_up_ms", capture.keyUpMs), ("audio_ms", capture.audioMs), ("voiced_ms", capture.voicedMs),
            ("audio_path", capture.audioPath), ("audio_expires_at", capture.audioExpiresAt?.timeIntervalSince1970),
            ("input_device_uid", capture.inputDeviceUID), ("input_device_name", capture.inputDeviceName),
            ("input_transport", capture.inputTransport), ("sample_rate_hz", capture.sampleRateHz),
            ("rms_db", capture.rmsDb), ("peak_db", capture.peakDb), ("noise_floor_db", capture.noiseFloorDb),
        ])
    }

    public func recordTranscription(_ id: String, _ record: TranscriptionRecord) throws {
        let t = record.transcription
        let timings = String(decoding: try JSONEncoder().encode(t.words), as: UTF8.self)
        let boost = try record.boostTerms.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try update(id, [
            ("status", DictationStatus.transcribed),
            ("asr_engine_id", t.engineID), ("asr_model_rev", t.modelRevision),
            ("asr_ms", Int((t.processingSeconds * 1000).rounded())),
            ("asr_confidence", t.confidence.map { Double($0) }), ("language", record.language),
            ("word_timings_json", timings), ("boost_terms_applied_json", boost),
            ("asr_done_ms", record.asrDoneMs), ("speech_onset_ms", record.speechOnsetMs),
            ("raw_text", record.rawText), ("words_raw", Self.wordCount(record.rawText)),
        ])
    }

    public func recordInsertion(_ id: String, _ record: InsertionRecord) throws {
        let cleanup = record.cleanup
        var columns: [(String, (any DatabaseValueConvertible)?)] = [
            ("status", DictationStatus.inserted),
            ("final_text", record.finalText), ("det_text", record.detText),
            ("words_final", Self.wordCount(record.finalText)), ("chars_final", record.finalText.count),
            ("cleaner_id", cleanup?.cleanerID), ("cleaner_rev", cleanup?.cleanerRev),
            ("cleanup_level", cleanup?.level), ("style", cleanup?.style), ("cleanup_ms", cleanup?.ms),
            ("cleanup_outcome", cleanup?.outcome), ("prompt_sha", cleanup?.promptSha),
            ("cleanup_done_ms", cleanup?.doneMs),
            ("insert_method", record.method), ("insert_outcome", record.outcome),
            ("focus_moved", record.focusMoved), ("paste_receipt_ms", record.pasteReceiptMs),
            ("insert_done_ms", record.insertDoneMs),
        ]
        if let target = record.target {
            columns += [
                ("app_bundle_id", target.bundleID), ("app_name", target.appName), ("url_domain", target.urlDomain),
                ("window_title", target.windowTitle), ("category", target.category), ("field_role", target.fieldRole),
                ("is_secure", target.isSecure),
            ]
        }
        try update(id, columns)
    }

    /// Ends an attempt that produced no insertion: cancelled, too_short, empty or failed.
    public func finish(_ id: String, status: DictationStatus, errorMessage: String? = nil) throws {
        switch status {
        case .cancelled, .tooShort, .empty, .failed: break
        default: throw TranscriptStoreError.notTerminal(status)
        }
        try update(id, [("status", status), ("error_message", errorMessage)])
    }

    /// Puts a cancelled dictation back to `started`, for an Undo that runs it after all. Only a cancelled row can be
    /// reopened; the staged writes then carry on from the capture.
    public func reopen(_ id: String) throws {
        try pool.write { db in
            guard let status = try DictationStatus.fetchOne(
                db, sql: "SELECT status FROM dictation WHERE id = ?", arguments: [id]
            ) else { throw TranscriptStoreError.unknownDictation(id) }
            guard status == .cancelled else { throw TranscriptStoreError.notCancelled(status) }
            try db.execute(
                sql: "UPDATE dictation SET status = ?, error_message = NULL WHERE id = ?",
                arguments: [DictationStatus.started, id]
            )
        }
    }

    public func appendEdits(_ id: String, _ edits: [EditOp]) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dictation WHERE id = ?)", arguments: [id]) == true else {
                throw TranscriptStoreError.unknownDictation(id)
            }
            for edit in edits {
                try db.execute(sql: """
                    INSERT INTO edit_op (dictation_id, stage, kind, from_text, to_text, word_delta, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, edit.stage, edit.kind.rawValue, edit.fromText, edit.toText, edit.wordDelta, edit.position])
            }
        }
    }

    /// Records that a spelling was offered, with no answer yet. Returns the row to settle with `recordCorrectionOutcome`.
    @discardableResult
    public func recordCorrectionOffer(
        dictationID: String, kind: CorrectionKind = .remember, heard: String, corrected: String, at date: Date = Date()
    ) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at)
                VALUES (?, ?, ?, ?, NULL, ?)
                """, arguments: [dictationID, kind.rawValue, heard, corrected, date.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    /// `true` when the user accepted, `false` when they declined, `nil` for no answer (the card timed out or was replaced).
    public func recordCorrectionOutcome(_ id: Int64, accepted: Bool?) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE correction SET accepted = ? WHERE id = ?", arguments: [accepted, id])
        }
    }

    public func corrections(dictationID: String) throws -> [CorrectionRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM correction WHERE dictation_id = ? ORDER BY id", arguments: [dictationID]).map {
                CorrectionRecord(
                    id: $0["id"], dictationID: $0["dictation_id"], kind: CorrectionKind(rawValue: $0["kind"]) ?? .remember,
                    heard: $0["heard"], corrected: $0["corrected"], accepted: $0["accepted"], createdAt: $0["created_at"]
                )
            }
        }
    }

    public func delete(_ id: String) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM dictation WHERE id = ?", arguments: [id]) }
    }

    /// Clears `audio_path` and `audio_expires_at` for rows whose audio was purged.
    public func clearAudio(ids: [String]) throws {
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE dictation SET audio_path = NULL, audio_expires_at = NULL WHERE id = ?", arguments: [id])
            }
        }
    }

    // MARK: Reads

    public func dictation(id: String) throws -> DictationRecord? {
        try pool.read { db in try DictationRecord.fetchOne(db, sql: "SELECT * FROM dictation WHERE id = ?", arguments: [id]) }
    }

    public func editOps(id: String) throws -> [EditOp] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM edit_op WHERE dictation_id = ? ORDER BY id", arguments: [id]).map { row in
                EditOp(
                    stage: row["stage"], kind: EditOp.Kind(rawValue: row["kind"]) ?? .replace,
                    fromText: row["from_text"], toText: row["to_text"], wordDelta: row["word_delta"], position: row["position"]
                )
            }
        }
    }

    public func recent(limit: Int) throws -> [DictationRecord] {
        try pool.read { db in
            try DictationRecord.fetchAll(db, sql: """
                SELECT * FROM dictation WHERE final_text IS NOT NULL ORDER BY started_at DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// `now` and `timeZone` are injected; nothing in here reads the clock.
    public func stats(now: Date, timeZone: TimeZone = .current) throws -> StatsSummary {
        let today = Streaks.localDay(for: now, in: timeZone)
        return try pool.read { db in
            let wordsToday = try Int.fetchOne(
                db, sql: "SELECT COALESCE(SUM(words_final), 0) FROM dictation WHERE local_day = ?", arguments: [today]
            ) ?? 0

            let recent = try Row.fetchAll(db, sql: """
                SELECT words_final, COALESCE(voiced_ms, audio_ms) AS duration_ms FROM dictation
                WHERE words_final > 0 AND audio_ms < \(Self.wpmMaxAudioMs)
                ORDER BY started_at DESC LIMIT \(Self.wpmSampleSize)
                """)
            let words = recent.reduce(0) { $0 + ($1["words_final"] as Int) }
            let durationMs = recent.reduce(0) { $0 + ($1["duration_ms"] as Int? ?? 0) }
            let wpm = durationMs > 0 ? Double(words) / (Double(durationMs) / 60_000) : 0

            let days = try String.fetchAll(
                db, sql: "SELECT DISTINCT local_day FROM dictation WHERE words_final > 0 ORDER BY local_day"
            )
            let streaks = Streaks.compute(days: days, today: today)
            return StatsSummary(
                wordsToday: wordsToday, recentWPM: wpm,
                currentStreakDays: streaks.current, longestStreakDays: streaks.longest
            )
        }
    }

    static let wpmSampleSize = 100
    static let wpmMaxAudioMs = 400_000

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: Internals

    private func update(_ id: String, _ columns: [(String, (any DatabaseValueConvertible)?)]) throws {
        let assignments = columns.map { "\($0.0) = ?" }.joined(separator: ", ")
        var arguments = StatementArguments(columns.map { $0.1 })
        arguments += [id]
        try pool.write { db in
            try db.execute(sql: "UPDATE dictation SET \(assignments) WHERE id = ?", arguments: arguments)
            if db.changesCount == 0 { throw TranscriptStoreError.unknownDictation(id) }
        }
    }
}
