import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct StatsPagesRenderTests {
    static let zone = TimeZone(secondsFromGMT: 0)!
    static let midnight = 1_792_281_600.0 // 2026-10-18 00:00 UTC
    static let now = Date(timeIntervalSince1970: midnight + 14 * 3_600 + 30 * 60)

    /// Eighteen October days (two gaps), a few takes spread over today, and one big old take for the records.
    static let sample: [DictationSample] = {
        var out: [DictationSample] = []
        for offset in 0..<18 where offset != 6 && offset != 7 {
            let start = midnight - Double(17 - offset) * 86_400
            for take in 0..<3 {
                let words = 80 + ((offset * 53 + take * 97) % 300)
                out.append(DictationSample(day: String(format: "2026-10-%02d", 1 + offset),
                                           startedAt: Date(timeIntervalSince1970: start + Double(9 + take * 3) * 3_600),
                                           words: words, durationMs: words * 380, appName: ["Slack", "Xcode", "Mail"][take]))
            }
        }
        out.append(DictationSample(day: "2026-10-12", startedAt: Date(timeIntervalSince1970: midnight - 6 * 86_400 + 13 * 3_600 + 600),
                                   words: 640, durationMs: 190_000, appName: "Notes"))
        return out
    }()

    static var snapshot: StatsSnapshot { StatsSnapshot.make(samples: sample, now: now, timeZone: zone) }

    private func render(_ snapshot: StatsSnapshot, dark: Bool, width: CGFloat = 800, name: String?) throws {
        FontRegistry.registerBundledFonts()
        let page = DesignPage(title: SettingsPage.stats.headline, summary: SettingsPage.stats.summary) {
            StatsPage(snapshot: snapshot, now: Self.now, timeZone: Self.zone)
        }
        let bitmap = try SettingsRender.render(page, dark: dark, size: NSSize(width: width, height: 1_100))
        #expect(bitmap.pixelsWide >= Int(width))
        if let name { try SettingsRender.save(bitmap, name: name) }
    }

    @Test func statsPageRendersLightAndDark() throws {
        let snapshot = Self.snapshot
        #expect(snapshot.report.wordsAllTime > 0)
        #expect(snapshot.todayTakes.count == 3)
        try render(snapshot, dark: false, name: "stats-light")
        try render(snapshot, dark: true, name: "stats-dark")
    }

    @Test func statsPageRendersTodayTapeWithHollowNeedles() throws {
        var snapshot = Self.snapshot
        let at: (Int) -> Date = { Date(timeIntervalSince1970: Self.midnight + Double($0)) }
        snapshot.todayTakes = [
            TodayTake(startedAt: at(8 * 3_600 + 41 * 60), secondsIntoDay: 8 * 3_600 + 41 * 60, words: 40, durationMs: 15_000, appName: "Mail"),
            TodayTake(startedAt: at(10 * 3_600), secondsIntoDay: 10 * 3_600, words: 0, durationMs: 9_000, appName: nil),
            TodayTake(startedAt: at(13 * 3_600 + 600), secondsIntoDay: 13 * 3_600 + 600, words: 402, durationMs: 151_000, appName: "Slack"),
            TodayTake(startedAt: at(14 * 3_600), secondsIntoDay: 14 * 3_600, words: 90, durationMs: 30_000, appName: "Xcode"),
        ]
        try render(snapshot, dark: false, name: "stats-tape-light")
        try render(snapshot, dark: true, name: "stats-tape-dark")
        try render(snapshot, dark: false, width: 520, name: "stats-narrow")
    }

    @Test func statsPageRendersEmptyPiecesAndEarlyTakes() throws {
        var snapshot = StatsSnapshot.make(samples: [], now: Self.now, timeZone: Self.zone)
        snapshot.daily = (0..<30).map { DailyWords(day: "2026-09-\(String(format: "%02d", min(28, $0 + 1)))", words: 0) }
        try render(snapshot, dark: false, name: nil)
        snapshot.todayTakes = [TodayTake(startedAt: Self.now, secondsIntoDay: 5 * 3_600, words: 12, durationMs: 4_000, appName: nil),
                               TodayTake(startedAt: Self.now, secondsIntoDay: 22 * 3_600, words: 0, durationMs: nil, appName: nil)]
        try render(snapshot, dark: true, name: nil)
    }

    @Test func tapeRangeWidensForEarlyAndLateTakes() {
        let early = TodayTake(startedAt: Self.now, secondsIntoDay: 5 * 3_600 + 10, words: 5, durationMs: nil, appName: nil)
        let late = TodayTake(startedAt: Self.now, secondsIntoDay: 21 * 3_600 + 10, words: 5, durationMs: nil, appName: nil)
        #expect(TapeRange(takes: [], nowSeconds: 9 * 3_600) == TapeRange(takes: [], nowSeconds: 1))
        let normal = TapeRange(takes: [], nowSeconds: 9 * 3_600)
        #expect(normal.start == 8 && normal.end == 20 && normal.ticks == [8, 10, 12, 14, 16, 18])
        let wide = TapeRange(takes: [early, late], nowSeconds: 22 * 3_600)
        #expect(wide.start == 5 && wide.end == 22)
        #expect(wide.fraction(5 * 3_600) == 0 && wide.fraction(22 * 3_600) == 1)
        #expect(TapeRange(takes: [], nowSeconds: 23 * 3_600 + 1).end == 24)
        #expect(TapeRange.label(12, edge: false) == "NOON" && TapeRange.label(14, edge: false) == "2" && TapeRange.label(20, edge: true) == "8 PM")
    }

    @Test func formatterHandlesEdges() {
        #expect(StatsFormat.date("2026-10-03") == "Oct 3, 2026")
        #expect(StatsFormat.date("junk") == "junk")
        #expect(StatsFormat.duration(minutes: 125) == "2 h 5 min")
        #expect(StatsFormat.duration(minutes: 0) == "None yet")
        #expect(StatsFormat.duration(minutes: 0.2) == "Under a minute")
        #expect(StatsFormat.speaking(ms: 190_000) == "3 min 10 s")
        #expect(StatsFormat.clock(seconds: 13 * 3_600 + 600) == "1:10 PM")
        #expect(StatsFormat.clock(seconds: 0) == "12:00 AM")
        #expect(StatsFormat.hourName(14) == "2 PM" && StatsFormat.hourName(0) == "12 AM" && StatsFormat.hourName(12) == "12 PM")
        #expect(StatsFormat.savedHeadline(minutes: 88 * 60) == "88 hours you didn't have to type.")
        #expect(StatsFormat.savedHeadline(minutes: 60) == "1 hour you didn't have to type.")
        #expect(StatsFormat.savedHeadline(minutes: 45) == "45 minutes you didn't have to type.")
        #expect(StatsFormat.savedHeadline(minutes: 0.2) == "Nothing saved yet.")
        #expect(StatsFormat.talking(minutes: 22 * 60 + 10) == "22 h 10 min" && StatsFormat.talking(minutes: 0) == "0 min")
        #expect(StatsFormat.recordDate("2026-10-09", today: "2026-10-18") == "Oct 9")
        #expect(StatsFormat.recordDate("2025-10-09", today: "2026-10-18") == "Oct 9, 2025")
    }

    @Test func meterSegmentsMatchTheMockup() {
        #expect(StatsFormat.meterSegment(158) == 15)
        #expect(StatsFormat.meterSegment(201) == 20)
        #expect(StatsFormat.meterSegment(40) == 3)
        #expect(StatsFormat.meterSegment(1_000) == 24)
        #expect(StatsFormat.meterSegment(nil) == nil && StatsFormat.meterSegment(0) == nil)
        #expect(StatsFormat.typistRatio(wpm: 150, typingWPM: 40) == "3.8 times a typist.")
        #expect(StatsFormat.typistRatio(wpm: 160, typingWPM: 40) == "4 times a typist.")
        #expect(StatsFormat.typistRatio(wpm: 45, typingWPM: 40) == nil)
        #expect(StatsFormat.typistRatio(wpm: nil, typingWPM: 40) == nil)
    }

    @Test func streakCaptionNamesTheLastMiss() {
        func days(_ words: [Int]) -> [DailyWords] { words.enumerated().map { DailyWords(day: "2026-10-\(String(format: "%02d", $0.offset + 1))", words: $0.element) } }
        let rule = "A day counts with one take, and today carries until midnight."
        #expect(StatsFormat.streakCaption(daily: days([3, 0, 4, 4, 4]), current: 3) == "Missed Oct 2, then 3 straight. \(rule)")
        #expect(StatsFormat.streakCaption(daily: days([3, 0, 4, 4, 0]), current: 2) == "Missed Oct 2, then 2 straight. \(rule)")
        #expect(StatsFormat.streakCaption(daily: days([4, 4, 4]), current: 3) == "3 straight. \(rule)")
        #expect(StatsFormat.streakCaption(daily: days([4, 0, 0]), current: 0) == "No streak running. \(rule)")
    }
}
