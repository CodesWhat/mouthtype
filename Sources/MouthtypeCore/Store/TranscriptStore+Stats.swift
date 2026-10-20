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

    /// The log reduced by SQL: per-day sums plus the two single-row records. Only counts and timings are read, never
    /// text, and secure takes are left out. The WPM rules are the ones in `StatsEngine`.
    static func fetchStatsAggregates(_ db: Database) throws -> StatsAggregates {
        let duration = "COALESCE(voiced_ms, audio_ms)"
        let qualifies = """
            words_final >= \(StatsEngine.minWPMWords) AND \(duration) >= \(StatsEngine.minWPMDurationMs)
            AND words_final * 60000.0 / \(duration) <= \(StatsEngine.maxPlausibleWPM)
            """
        let base = "FROM dictation WHERE words_final > 0 AND COALESCE(is_secure, 0) = 0"
        let days = try Row.fetchAll(db, sql: """
            SELECT local_day, COUNT(*) AS n, SUM(words_final) AS words,
                SUM(CASE WHEN \(qualifies) THEN words_final END) AS rated_words,
                SUM(CASE WHEN \(qualifies) THEN \(duration) END) AS rated_ms,
                SUM(CASE WHEN \(duration) > 0 THEN words_final END) AS timed_words,
                SUM(CASE WHEN \(duration) > 0 THEN \(duration) END) AS timed_ms
            \(base) GROUP BY local_day
            """).map {
            StatsAggregates.Day(
                day: $0["local_day"], count: $0["n"], words: $0["words"], ratedWords: $0["rated_words"] ?? 0,
                ratedMs: $0["rated_ms"] ?? 0, timedWords: $0["timed_words"] ?? 0, timedMs: $0["timed_ms"] ?? 0)
        }
        // Earliest take wins a tie on both records.
        let best = try Row.fetchOne(db, sql: """
            SELECT local_day, words_final * 60000.0 / \(duration) AS rate \(base) AND \(qualifies)
            ORDER BY rate DESC, started_at ASC LIMIT 1
            """).map { (rate: $0["rate"] as Double, day: $0["local_day"] as String) }
        let longest = try Row.fetchOne(db, sql: """
            SELECT local_day, words_final, \(duration) AS duration_ms \(base)
            ORDER BY words_final DESC, started_at ASC LIMIT 1
            """).map { LongestDictation(words: $0["words_final"], durationMs: $0["duration_ms"], day: $0["local_day"]) }
        return StatsAggregates(days: days, bestWPM: best, longest: longest)
    }

    /// Everything the Stats and Records pages show, computed in one read. Runs on the caller's thread; the pages call it
    /// off the main thread.
    public func statsSnapshot(now: Date, timeZone: TimeZone = .current,
                              typingWPM: Double = StatsEngine.defaultTypingWPM) throws -> StatsSnapshot {
        let aggregates = try pool.read { db in try Self.fetchStatsAggregates(db) }
        return StatsSnapshot.make(aggregates: aggregates, now: now, timeZone: timeZone, typingWPM: typingWPM)
    }

    /// Calls `onChange` on the main queue now and whenever the dictation table changes. The snapshot is computed on the
    /// database reader queue, so no statistics work happens on the main thread. A write that leaves the numbers
    /// unchanged (a take that has only just started, a secure take) is recomputed from the covering index but not
    /// delivered.
    public func observeStats(typingWPM: Double = StatsEngine.defaultTypingWPM, timeZone: TimeZone = .current,
                             now: @escaping @Sendable () -> Date = { Date() },
                             onError: @escaping @Sendable (Error) -> Void,
                             onChange: @escaping @Sendable (StatsSnapshot) -> Void) -> TakesObservation {
        let observation = ValueObservation.tracking { db in
            StatsSnapshot.make(aggregates: try Self.fetchStatsAggregates(db), now: now(), timeZone: timeZone, typingWPM: typingWPM)
        }.removeDuplicates()
        let cancellable = observation.start(in: pool, scheduling: .async(onQueue: .main), onError: onError, onChange: onChange)
        return TakesObservation(cancellable)
    }

    public func statsEngine(typingWPM: Double = StatsEngine.defaultTypingWPM) throws -> StatsEngine {
        StatsEngine(samples: try statsSamples(), typingWPM: typingWPM)
    }
}
