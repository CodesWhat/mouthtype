import Foundation
import GRDB

extension TranscriptStore {
    /// Every dictation that produced words, as the plain numbers `StatsEngine` needs. Only counts and timings are
    /// read, never text, and takes from secure fields are left out of every number.
    public func statsSamples() throws -> [DictationSample] {
        try pool.read { db in try Self.fetchStatsSamples(db) }
    }

    static func fetchStatsSamples(_ db: Database) throws -> [DictationSample] {
        try Row.fetchAll(db, sql: """
                SELECT local_day, started_at, words_final, COALESCE(voiced_ms, audio_ms) AS duration_ms
                FROM dictation WHERE words_final > 0 AND COALESCE(is_secure, 0) = 0 ORDER BY started_at
                """).map {
                DictationSample(
                    day: $0["local_day"], startedAt: Date(timeIntervalSince1970: $0["started_at"]),
                    words: $0["words_final"], durationMs: $0["duration_ms"]
                )
        }
    }

    /// Everything the Stats and Records pages show, computed in one read. Runs on the caller's thread; the pages call it
    /// off the main thread.
    public func statsSnapshot(now: Date, timeZone: TimeZone = .current,
                              typingWPM: Double = StatsEngine.defaultTypingWPM) throws -> StatsSnapshot {
        StatsSnapshot.make(samples: try statsSamples(), now: now, timeZone: timeZone, typingWPM: typingWPM)
    }

    /// Calls `onChange` on the main queue now and whenever the dictation table changes. The snapshot is computed on the
    /// database reader queue, so no statistics work happens on the main thread.
    public func observeStats(typingWPM: Double = StatsEngine.defaultTypingWPM, timeZone: TimeZone = .current,
                             now: @escaping @Sendable () -> Date = { Date() },
                             onError: @escaping @Sendable (Error) -> Void,
                             onChange: @escaping @Sendable (StatsSnapshot) -> Void) -> TakesObservation {
        let observation = ValueObservation.tracking { db in
            StatsSnapshot.make(samples: try Self.fetchStatsSamples(db), now: now(), timeZone: timeZone, typingWPM: typingWPM)
        }
        let cancellable = observation.start(in: pool, scheduling: .async(onQueue: .main), onError: onError, onChange: onChange)
        return TakesObservation(cancellable)
    }

    public func statsEngine(typingWPM: Double = StatsEngine.defaultTypingWPM) throws -> StatsEngine {
        StatsEngine(samples: try statsSamples(), typingWPM: typingWPM)
    }
}
