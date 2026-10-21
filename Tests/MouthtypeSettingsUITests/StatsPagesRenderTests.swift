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
        #expect(StatsFormat.typistRatio(wpm: 150, typingWPM: 40) == "3.8× a typist.")
        #expect(StatsFormat.typistRatio(wpm: 160, typingWPM: 40) == "4× a typist.")
        #expect(StatsFormat.typistRatio(wpm: 45, typingWPM: 40) == nil)
        #expect(StatsFormat.typistRatio(wpm: nil, typingWPM: 40) == nil)
    }

    @Test func streakTodayIsHollowOnlyBeforeTheFirstTake() throws {
        var snapshot = Self.snapshot
        snapshot.daily[snapshot.daily.count - 1].words = 0
        try render(snapshot, dark: false, name: "stats-streak-today-pending-light")
        try render(snapshot, dark: true, name: "stats-streak-today-pending-dark")
        snapshot.daily[snapshot.daily.count - 1].words = 120
        try render(snapshot, dark: false, name: "stats-streak-today-lit-light")
    }

    // MARK: Tape

    private func take(_ seconds: Int, words: Int, app: String? = "Slack") -> TodayTake {
        TodayTake(startedAt: Date(timeIntervalSince1970: Self.midnight + Double(seconds)), secondsIntoDay: seconds, words: words,
                  durationMs: words * 380, appName: app)
    }

    /// 48 takes from 9 AM to 2:30 PM, a cluster of five inside one minute, one long take and two audio-only takes.
    private var denseDay: [TodayTake] {
        var takes: [TodayTake] = (0..<40).map { take(9 * 3_600 + $0 * 480, words: 12 + ($0 * 37) % 60) }
        takes += (0..<5).map { take(11 * 3_600 + 10 * 60 + $0 * 10, words: 20 + $0 * 5) }
        takes.append(take(13 * 3_600, words: 640, app: "Notes"))
        takes += [take(10 * 3_600 + 25 * 60, words: 0, app: nil), take(12 * 3_600 + 2 * 60, words: 0, app: nil)]
        return takes.sorted { $0.secondsIntoDay < $1.secondsIntoDay }
    }

    @Test func tapeRendersADenseAndASparseDay() throws {
        var snapshot = Self.snapshot
        snapshot.todayTakes = denseDay
        try render(snapshot, dark: false, name: "stats-tape-dense-light")
        try render(snapshot, dark: true, name: "stats-tape-dense-dark")
        snapshot.todayTakes = [take(13 * 3_600 + 600, words: 60), take(14 * 3_600 + 10, words: 140)]
        try render(snapshot, dark: false, name: "stats-tape-sparse-light")
        try render(snapshot, dark: true, name: "stats-tape-sparse-dark")
    }

    @Test func tapeRangeFitsTheDaysActivity() {
        let nine = take(9 * 3_600 + 5 * 60, words: 5)
        let range = TapeRange(takes: [nine], nowSeconds: 14 * 3_600 + 30 * 60)
        #expect(range.start == 8 && range.end == 15)
        // Nothing yet: three hours around now, never wider than the day.
        let empty = TapeRange(takes: [], nowSeconds: 9 * 3_600)
        #expect(empty.start == 8 && empty.end == 11 && empty.end - empty.start >= TapeRange.minimumHours)
        let late = TapeRange(takes: [take(23 * 3_600 + 30 * 60, words: 5)], nowSeconds: 23 * 3_600 + 40 * 60)
        #expect(late.end == 24 && late.start == 21)
        let wide = TapeRange(takes: [take(5 * 3_600 + 10, words: 5)], nowSeconds: 22 * 3_600)
        #expect(wide.start == 4 && wide.end == 23)
        #expect(wide.fraction(wide.start * 3_600) == 0 && wide.fraction(wide.end * 3_600) == 1)
        #expect(TapeRange.label(12, edge: false) == "NOON" && TapeRange.label(14, edge: false) == "2" && TapeRange.label(20, edge: true) == "8 PM")
    }

    @Test func hoverClearsWhenThePointerLeaves() {
        let takes = denseDay
        let range = TapeRange(takes: takes, nowSeconds: 14 * 3_600 + 30 * 60)
        let slots = TapeSlots.merge(takes, range: range, width: 600)
        let over = TapeSlots.hoveredIndex(slots, pointerX: slots[0].x + 1)
        #expect(over == 0)
        #expect(TapeSlots.hoveredIndex(slots, pointerX: nil) == nil)
        #expect(TapeSlots.hoveredIndex(slots, pointerX: slots[0].x - 200) == nil)
        #expect(TapeSlots.hoveredIndex([], pointerX: 10) == nil)
    }

    @Test func slotsNeverOverlapAndKeepTheirWords() {
        let takes = denseDay
        let range = TapeRange(takes: takes, nowSeconds: 14 * 3_600 + 30 * 60)
        for width in [300.0, 600.0, 900.0] {
            let slots = TapeSlots.merge(takes, range: range, width: width)
            for index in slots.indices.dropFirst() { #expect(slots[index].x - slots[index - 1].x >= TapeSlots.minimumSpacing) }
            let slotCount: Int = slots.reduce(0) { $0 + $1.count }
            let slotWords: Int = slots.reduce(0) { $0 + $1.words }
            let slotHollow: Int = slots.reduce(0) { $0 + $1.hollow }
            let takeWords: Int = takes.reduce(0) { $0 + $1.words }
            #expect(slotCount == takes.count)
            #expect(slotWords == takeWords)
            #expect(slotHollow == 2)
        }
        let narrow = TapeSlots.merge(takes, range: range, width: 300).count
        let wide = TapeSlots.merge(takes, range: range, width: 900).count
        #expect(narrow < wide)
    }

    @Test func closeTakesMergeIntoOneSlotWithSummedWordsAndALabel() {
        let range = TapeRange(takes: [], nowSeconds: 15 * 3_600)
        let takes = [take(14 * 3_600 + 50 * 60, words: 100), take(14 * 3_600 + 54 * 60, words: 200), take(14 * 3_600 + 58 * 60, words: 112)]
        let slots = TapeSlots.merge(takes, range: range, width: 100)
        #expect(slots.count == 1)
        #expect(slots[0].count == 3 && slots[0].words == 412 && slots[0].take == nil)
        #expect(slots[0].summary == "3 takes · 412 words · 2:50 to 2:58 PM")
        let across = TapeSlot(x: 0, count: 2, words: 5, hollow: 0, firstSeconds: 11 * 3_600 + 55 * 60, lastSeconds: 12 * 3_600 + 5 * 60, take: nil)
        #expect(across.timeLabel == "11:55 AM to 12:05 PM")
        let single = TapeSlots.merge([takes[0]], range: range, width: 100)[0]
        #expect(single.take == takes[0] && single.timeLabel == "2:50 PM" && single.summary == "1 take · 100 words · 2:50 PM")
    }

    @Test func hollowTakesStayDistinguishableAfterMerging() {
        let range = TapeRange(takes: [], nowSeconds: 15 * 3_600)
        let mixed = TapeSlots.merge([take(14 * 3_600, words: 50), take(14 * 3_600 + 30, words: 0, app: nil)], range: range, width: 100)
        #expect(mixed.count == 1 && mixed[0].hasHollowCap && !mixed[0].isAllHollow && mixed[0].summary.hasSuffix("1 audio only"))
        let hollow = TapeSlots.merge([take(14 * 3_600, words: 0, app: nil), take(14 * 3_600 + 30, words: 0, app: nil)], range: range, width: 100)
        #expect(hollow[0].isAllHollow && !hollow[0].hasHollowCap)
    }

    @Test func needleHeightScalesBySquareRootAndStaysMonotonic() {
        let heights = [1, 10, 100, 400, 640].map { TapeSlots.height(words: $0, maxWords: 640) }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 })
        #expect(heights.last == 44)
        // A 640-word take doesn't flatten a 40-word one: linear would give it under 7% of the height.
        #expect(TapeSlots.height(words: 40, maxWords: 640) > 4 + 40 * 0.2)
    }

    @Test func todaysTapeShowsForAnAudioOnlyHistory() throws {
        var snapshot = StatsSnapshot.make(samples: [], now: Self.now, timeZone: Self.zone)
        #expect(!snapshot.hasHistory && !StatsHostPage.showsTape(snapshot))
        snapshot.todayTakes = [take(9 * 3_600, words: 0, app: nil)]
        #expect(!snapshot.hasHistory && StatsHostPage.showsTape(snapshot))
    }
}
