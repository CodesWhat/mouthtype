import Foundation
import GRDB

/// One stored dictation as the scoring tools need it.
public struct HistoryEntry: Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var rawText: String
    public var detText: String?
    public var finalText: String?
}

/// Reads dictations from a transcript database without ever writing to it: no migration, no directory creation,
/// and SQLite opens the file read-only.
public enum TranscriptHistory {
    /// The newest `limit` dictations that have raw text (all of them when nil), oldest first.
    public static func entries(at url: URL, limit: Int? = nil, since: Date? = nil) throws -> [HistoryEntry] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, started_at, raw_text, det_text, final_text FROM dictation
                WHERE raw_text IS NOT NULL AND raw_text != '' AND started_at >= ?
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [since?.timeIntervalSince1970 ?? 0, limit ?? -1])
        }
        return rows.reversed().map { row in
            HistoryEntry(
                id: row["id"], startedAt: Date(timeIntervalSince1970: row["started_at"]), rawText: row["raw_text"],
                detText: row["det_text"], finalText: row["final_text"]
            )
        }
    }
}
