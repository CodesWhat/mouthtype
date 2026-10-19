import Foundation
import GRDB

extension TranscriptStore {
    /// Every dictation that produced words, as the plain numbers `StatsEngine` needs. Only counts and timings are
    /// read, never text.
    public func statsSamples() throws -> [DictationSample] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT local_day, started_at, words_final, COALESCE(voiced_ms, audio_ms) AS duration_ms
                FROM dictation WHERE words_final > 0 ORDER BY started_at
                """).map {
                DictationSample(
                    day: $0["local_day"], startedAt: Date(timeIntervalSince1970: $0["started_at"]),
                    words: $0["words_final"], durationMs: $0["duration_ms"]
                )
            }
        }
    }

    public func statsEngine(typingWPM: Double = StatsEngine.defaultTypingWPM) throws -> StatsEngine {
        StatsEngine(samples: try statsSamples(), typingWPM: typingWPM)
    }
}
