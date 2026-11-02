import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

/// The SQL behind the achievements, on a temp store: local days across time zones, secure takes left out, and the night window.
@Suite struct AchievementExtrasTests {
    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-ach-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    /// 2026-10-01 00:00 UTC.
    private static let origin = 1_790_812_800.0

    @discardableResult
    private func insert(
        _ store: TranscriptStore, day: String, at: Double, offset: Int = 0, words: Int = 10, voiced: Int? = 6_000,
        mode: String = "hold", app: String? = nil, secure: Int? = nil
    ) throws -> String {
        let id = UUID().uuidString
        try store.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, words_final, voiced_ms, app_name, is_secure)
                    VALUES (?, ?, ?, ?, ?, 'fn', 'inserted', ?, ?, ?, ?)
                    """, arguments: [id, at, offset, day, mode, words, voiced, app, secure])
        }
        return id
    }

    private let zone = TimeZone(secondsFromGMT: 0)!
    private var now: Date { Date(timeIntervalSince1970: Self.origin + 10 * 86_400) }

    private func evaluate(_ store: TranscriptStore) throws -> [AchievementStatus] {
        let snapshot = try store.statsSnapshot(now: now, timeZone: zone)
        return AchievementEngine.evaluate(AchievementInput(snapshot: snapshot, extras: try store.achievementExtras(calibrated: false)))
    }

    private func state(_ statuses: [AchievementStatus], _ id: String) -> AchievementState { statuses.first { $0.id == id }!.state }

    @Test func streaksFollowTheStoredLocalDayNotUTC() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Three local days, but only two UTC dates (and the first two share one).
        try insert(store, day: "2026-10-01", at: Self.origin + 20 * 3_600, offset: -28_800)
        try insert(store, day: "2026-10-02", at: Self.origin + 21 * 3_600, offset: 32_400)
        try insert(store, day: "2026-10-03", at: Self.origin + 3 * 86_400 + 3_600, offset: -28_800)
        let statuses = try evaluate(store)
        #expect(state(statuses, "three_row") == .earned(day: "2026-10-03"))
        #expect(!statuses.first { $0.id == "no_days_off" }!.isEarned)
    }

    @Test func oneLocalDayAcrossTwoUTCDatesIsOneDay() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-10-01", at: Self.origin + 20 * 3_600, offset: -28_800)
        try insert(store, day: "2026-10-01", at: Self.origin + 86_400 + 3_600, offset: -28_800)
        try insert(store, day: "2026-10-02", at: Self.origin + 86_400 + 20 * 3_600, offset: -28_800)
        let statuses = try evaluate(store)
        #expect(!statuses.first { $0.id == "three_row" }!.isEarned)
    }

    @Test func nightOwlUsesTheTakesOwnLocalClock() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 03:59:59 local with a +8 h offset: 19:59:59 UTC.
        try insert(store, day: "2026-10-02", at: Self.origin + 19 * 3_600 + 3_599, offset: 28_800, words: 20)
        #expect(state(try evaluate(store), "night_owl") == .earned(day: "2026-10-02"))

        let (other, otherDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        // 04:00:00 local, 19 words at 02:00, and a long take at 12:00: none counts.
        try insert(other, day: "2026-10-02", at: Self.origin + 20 * 3_600, offset: 28_800, words: 40)
        try insert(other, day: "2026-10-02", at: Self.origin + 2 * 3_600, words: 19)
        try insert(other, day: "2026-10-02", at: Self.origin + 12 * 3_600, words: 90)
        #expect(state(try evaluate(other), "night_owl") == .hidden)

        let (midnight, midnightDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: midnightDir) }
        try insert(midnight, day: "2026-10-01", at: Self.origin, words: 20)
        #expect(state(try evaluate(midnight), "night_owl") == .earned(day: "2026-10-01"))
    }

    @Test func secureTakesNeverCount() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<12 {
            let id = try insert(
                store, day: "2026-10-01", at: Self.origin + Double(index) * 60, words: 900, voiced: 400_000, mode: "hands_free",
                app: "App \(index)", secure: 1)
            try store.pool.write { db in
                try db.execute(sql: "INSERT INTO edit_op (dictation_id, stage, kind) VALUES (?, 'snippet', 'expand')", arguments: [id])
                try db.execute(
                    sql: "INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES (?, 'remember', 'a', 'b', 1, 0)",
                    arguments: [id])
            }
        }
        let extras = try store.achievementExtras(calibrated: false)
        #expect(extras == AchievementExtras())
        let statuses = try evaluate(store)
        #expect(statuses.filter(\.isEarned).isEmpty)
    }

    @Test func handsFreeAppsSnippetsAndSpellingsCountWithTheirDays() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-10-01", at: Self.origin, app: "Slack")
        try insert(store, day: "2026-10-02", at: Self.origin + 86_400, app: "Mail")
        try insert(store, day: "2026-10-02", at: Self.origin + 86_400 + 5, app: "Mail")
        let third = try insert(store, day: "2026-10-03", at: Self.origin + 2 * 86_400, mode: "hands_free", app: "Xcode")
        try insert(store, day: "2026-10-04", at: Self.origin + 3 * 86_400, app: "")
        var ids: [String] = []
        for index in 0..<10 {
            let id = try insert(store, day: "2026-10-0\(min(index, 4) + 1)", at: Self.origin + Double(index) * 86_400 / 4)
            ids.append(id)
        }
        try store.pool.write { db in
            for id in ids.prefix(9) { try db.execute(sql: "INSERT INTO edit_op (dictation_id, stage, kind) VALUES (?, 'snippet', 'expand')", arguments: [id]) }
            try db.execute(sql: "INSERT INTO edit_op (dictation_id, stage, kind) VALUES (?, 'filler', 'remove')", arguments: [third])
            try db.execute(
                sql: "INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES (?, 'remember', 'a', 'b', 0, 0)",
                arguments: [third])
        }
        var statuses = try evaluate(store)
        #expect(state(statuses, "many_apps") == .earned(day: "2026-10-03"))
        #expect(state(statuses, "hands_free") == .earned(day: "2026-10-03"))
        #expect(!statuses.first { $0.id == "shortcut" }!.isEarned)
        #expect(!statuses.first { $0.id == "proper_noun" }!.isEarned)
        // The tenth snippet and an accepted spelling.
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO edit_op (dictation_id, stage, kind) VALUES (?, 'snippet', 'expand')", arguments: [ids[9]])
            try db.execute(
                sql: "INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES (?, 'remember', 'c', 'd', 1, 0)",
                arguments: [third])
            try db.execute(
                sql: "INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES (?, 'forget', 'e', 'f', 1, 0)",
                arguments: [ids[0]])
        }
        statuses = try evaluate(store)
        #expect(statuses.first { $0.id == "shortcut" }!.isEarned)
        #expect(state(statuses, "proper_noun") == .earned(day: "2026-10-03"))
    }

    @Test func filibusterUsesTheLongestTakeByTimeNotByWords() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-10-01", at: Self.origin, words: 640, voiced: 120_000)
        try insert(store, day: "2026-10-02", at: Self.origin + 86_400, words: 30, voiced: 299_999)
        #expect(state(try evaluate(store), "filibuster") == .hidden)
        try insert(store, day: "2026-10-03", at: Self.origin + 2 * 86_400, words: 40, voiced: 300_000)
        #expect(state(try evaluate(store), "filibuster") == .earned(day: "2026-10-03"))
    }

    @Test func welcomeBackComesFromTheDaysWithWords() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-08-01", at: Self.origin - 60 * 86_400)
        try insert(store, day: "2026-09-01", at: Self.origin - 30 * 86_400)
        #expect(state(try evaluate(store), "welcome_back") == .earned(day: "2026-09-01"))
    }
}
