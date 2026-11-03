import Foundation
import GRDB

extension TranscriptStore {
    /// The small facts the achievements need beyond the stats snapshot. Only counts, days and timings are read, never text, and
    /// takes from secure fields are left out of every figure. Runs on the caller's thread; the model calls it off the main thread.
    public func achievementExtras(calibrated: Bool) throws -> AchievementExtras {
        try pool.read { db in try Self.fetchAchievementExtras(db, calibrated: calibrated) }
    }

    static func fetchAchievementExtras(_ db: Database, calibrated: Bool) throws -> AchievementExtras {
        let duration = "COALESCE(voiced_ms, audio_ms)"
        let base = "FROM dictation WHERE words_final > 0 AND COALESCE(is_secure, 0) = 0"
        var extras = AchievementExtras(calibrated: calibrated)

        extras.days = try Row.fetchAll(
            db,
            sql: """
                SELECT local_day, COUNT(*) AS n, SUM(words_final) AS words,
                    SUM(CASE WHEN \(duration) > 0 THEN words_final END) AS timed_words,
                    SUM(CASE WHEN \(duration) > 0 THEN \(duration) END) AS timed_ms
                \(base) GROUP BY local_day ORDER BY local_day
                """
        ).compactMap { row in
            let day: String = row["local_day"]
            guard Streaks.dayNumber(day) != nil else { return nil }
            return AchievementExtras.Day(
                day: day, takes: row["n"], words: row["words"], timedWords: row["timed_words"] ?? 0, timedMs: row["timed_ms"] ?? 0)
        }

        // Apps in the order they first appeared.
        let apps = try Row.fetchAll(
            db,
            sql: """
                SELECT app_name, MIN(local_day) AS first_day \(base) AND app_name IS NOT NULL AND app_name != ''
                GROUP BY app_name ORDER BY MIN(started_at)
                """)
        extras.distinctApps = apps.count
        if apps.count >= 3 { extras.thirdAppDay = apps[2]["first_day"] }

        if let row = try Row.fetchOne(
            db, sql: "SELECT COUNT(*) AS n, MIN(local_day) AS first_day \(base) AND mode = 'hands_free'")
        {
            extras.handsFreeCount = row["n"]
            extras.handsFreeFirstDay = row["first_day"]
        }

        let snippets = """
            FROM edit_op e JOIN dictation d ON d.id = e.dictation_id
            WHERE e.stage = 'snippet' AND COALESCE(d.is_secure, 0) = 0
            """
        extras.snippetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(snippets)") ?? 0
        if extras.snippetCount >= 10 {
            extras.snippetTenthDay = try String.fetchOne(
                db, sql: "SELECT d.local_day \(snippets) ORDER BY d.started_at, e.id LIMIT 1 OFFSET 9")
        }

        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS n, MIN(d.local_day) AS first_day
                FROM correction c JOIN dictation d ON d.id = c.dictation_id
                WHERE c.kind = 'remember' AND c.accepted = 1 AND COALESCE(d.is_secure, 0) = 0
                """)
        {
            extras.rememberedCount = row["n"]
            extras.firstRememberedDay = row["first_day"]
        }

        // The stored offset gives the local time of day, so the hour follows the zone the take was made in.
        extras.nightOwlDay = try String.fetchOne(
            db,
            sql: """
                SELECT MIN(local_day) \(base) AND words_final >= 20
                AND ((CAST(started_at AS INTEGER) + utc_offset_s) % 86400 + 86400) % 86400 < 14400
                """)

        if let row = try Row.fetchOne(
            db,
            sql: "SELECT local_day, \(duration) AS ms \(base) AND \(duration) > 0 ORDER BY ms DESC, started_at ASC LIMIT 1")
        {
            extras.longestDurationMs = row["ms"]
            extras.longestDurationDay = row["local_day"]
        }
        return extras
    }
}
