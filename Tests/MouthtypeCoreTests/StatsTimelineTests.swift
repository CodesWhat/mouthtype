import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct StatsTimelineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func secondsIntoDayUsesTheStoredOffset() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 17:46:40 UTC
        #expect(StatsTimeline.secondsIntoDay(startedAt: at, utcOffsetSeconds: 0) == 17 * 3_600 + 46 * 60 + 40)
        #expect(StatsTimeline.hour(startedAt: at, utcOffsetSeconds: 0) == 17)
        #expect(StatsTimeline.hour(startedAt: at, utcOffsetSeconds: -8 * 3_600) == 9)
        // Crossing midnight backwards wraps into the previous local day instead of going negative.
        let early = Date(timeIntervalSince1970: 1_792_000_000 - 17 * 3_600)
        #expect(StatsTimeline.hour(startedAt: early, utcOffsetSeconds: -3_600) == 23)
        #expect(StatsTimeline.secondsIntoDay(of: at, in: utc) == 17 * 3_600 + 46 * 60 + 40)
    }

    @Test func peakHourPicksTheEarliestOfATie() {
        var hourly = [Int](repeating: 0, count: 24)
        #expect(StatsTimeline.peakHour(hourly) == nil)
        hourly[14] = 50; hourly[9] = 50; hourly[3] = 10
        #expect(StatsTimeline.peakHour(hourly) == 9)
    }

    @Test func streakDotsCarryThroughAnEmptyToday() {
        func days(_ words: [Int]) -> [DailyWords] { words.enumerated().map { DailyWords(day: "2026-10-\(String(format: "%02d", $0.offset + 1))", words: $0.element) } }
        #expect(StatsTimeline.streakLit(daily: days([0, 5, 5, 5]), currentStreak: 3) == [false, true, true, true])
        // Today has no take yet: the run ends yesterday and today's dot stays dark.
        #expect(StatsTimeline.streakLit(daily: days([0, 5, 5, 0]), currentStreak: 2) == [false, true, true, false])
        #expect(StatsTimeline.streakLit(daily: days([5, 0, 0, 0]), currentStreak: 0) == [false, false, false, false])
        #expect(StatsTimeline.streakLit(daily: [], currentStreak: 4) == [])
    }

    @Test func todaySummaryLeavesUntimedTakesOutOfTypingAvoided() {
        let base = Date(timeIntervalSince1970: 0)
        let takes = [
            TodayTake(startedAt: base, secondsIntoDay: 0, words: 400, durationMs: 60_000, appName: nil),  // 10 min typing, 1 talking
            TodayTake(startedAt: base, secondsIntoDay: 60, words: 40, durationMs: nil, appName: nil),  // untimed
            TodayTake(startedAt: base, secondsIntoDay: 120, words: 0, durationMs: 5_000, appName: nil),  // hollow
        ]
        let summary = TodaySummary(takes: takes)
        #expect(summary.takes == 3)
        #expect(summary.words == 440)
        #expect(summary.speakingMs == 65_000)
        #expect(abs(summary.minutesAvoided - (10 - 65.0 / 60)) < 1e-9)
        #expect(takes[2].hasTranscript == false)
        #expect(TodaySummary(takes: []).minutesAvoided == 0)
    }

    // MARK: SQL

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-timeline-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    private func insert(
        _ store: TranscriptStore, day: String, at: Double, offset: Int = 0, words: Int?, audioPath: String? = nil,
        app: String? = nil, secure: Int? = nil
    ) throws {
        try store.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, words_final, voiced_ms, audio_ms,
                        audio_path, app_name, is_secure)
                    VALUES (?, ?, ?, ?, 'dictate', 'hold', 'inserted', ?, 6000, 6000, ?, ?, ?)
                    """, arguments: [UUID().uuidString, at, offset, day, words, audioPath, app, secure])
        }
    }

    @Test func hourBucketsAndTodayTapeComeFromTheLog() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 17:46:40 UTC
        let midnight = 1_792_000_000.0 - Double(17 * 3_600 + 46 * 60 + 40)
        try insert(store, day: "2026-10-14", at: midnight + 9 * 3_600 + 5, words: 30, app: "Slack")
        try insert(store, day: "2026-10-14", at: midnight + 9 * 3_600 + 900, words: 20)
        try insert(store, day: "2026-10-14", at: midnight + 14 * 3_600, words: 100)
        // Saved audio, no transcript: on the tape, not in the words.
        try insert(store, day: "2026-10-14", at: midnight + 11 * 3_600, words: nil, audioPath: "/tmp/a.caf")
        // No audio and no words: nothing to draw.
        try insert(store, day: "2026-10-14", at: midnight + 12 * 3_600, words: 0)
        try insert(store, day: "2026-10-14", at: midnight + 13 * 3_600, words: 50, secure: 1)
        // 29 days back is inside the window, 30 days back is not.
        try insert(store, day: "2026-09-15", at: midnight - 29 * 86_400 + 3 * 3_600, words: 7)
        try insert(store, day: "2026-09-14", at: midnight - 30 * 86_400 + 3 * 3_600, words: 1_000)
        // A take logged at UTC-8 is at 08:00 local even though it is 16:00 UTC.
        try insert(store, day: "2026-10-14", at: midnight + 16 * 3_600, offset: -8 * 3_600, words: 4)

        let snapshot = try store.statsSnapshot(now: now, timeZone: utc)
        #expect(snapshot.hourlyWords.count == 24)
        #expect(snapshot.hourlyWords[9] == 50)
        #expect(snapshot.hourlyWords[14] == 100)
        #expect(snapshot.hourlyWords[3] == 7)
        #expect(snapshot.hourlyWords[8] == 4)
        #expect(snapshot.hourlyWords.reduce(0, +) == 161)
        #expect(StatsTimeline.peakHour(snapshot.hourlyWords) == 14)

        let takes = snapshot.todayTakes
        #expect(takes.map(\.secondsIntoDay) == [8 * 3_600, 9 * 3_600 + 5, 9 * 3_600 + 900, 11 * 3_600, 14 * 3_600])
        #expect(takes.map(\.words) == [4, 30, 20, 0, 100])
        #expect(takes.map(\.hasTranscript) == [true, true, true, false, true])
        #expect(takes[1].appName == "Slack")
        #expect(takes[3].durationMs == 6_000)
        #expect(snapshot.report.firstDay == "2026-09-14")
        #expect(snapshot.report.speakingMinutes > 0)
    }

    @Test func emptyLogHasEmptyTimeline() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = try store.statsSnapshot(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: utc)
        #expect(snapshot.hourlyWords == [Int](repeating: 0, count: 24))
        #expect(snapshot.todayTakes.isEmpty)
        #expect(snapshot.report.firstDay == nil)
        #expect(snapshot.daily.isEmpty)
    }

    @Test func dailyWindowIsThirtyDays() {
        #expect(StatsSnapshot.dailyWindowDays == 30)
        let sample = DictationSample(day: "2026-10-14", startedAt: Date(timeIntervalSince1970: 1_792_000_000), words: 10, durationMs: 5_000)
        let snapshot = StatsSnapshot.make(samples: [sample], now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: utc)
        #expect(snapshot.daily.count == 30)
        #expect(snapshot.daily.last == DailyWords(day: "2026-10-14", words: 10))
        #expect(snapshot.todayTakes.count == 1)
        #expect(snapshot.hourlyWords[17] == 10)
    }
}
