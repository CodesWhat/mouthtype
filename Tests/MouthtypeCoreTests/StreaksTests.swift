import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct StreaksTests {
    @Test func empty() {
        let s = Streaks.compute(days: [], today: "2026-10-12")
        #expect(s.current == 0 && s.longest == 0)
    }

    @Test func singleDayToday() {
        let s = Streaks.compute(days: ["2026-10-12"], today: "2026-10-12")
        #expect(s.current == 1 && s.longest == 1)
    }

    @Test func gapBreaksTheRun() {
        let s = Streaks.compute(days: ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-11", "2026-10-12"], today: "2026-10-12")
        #expect(s.current == 2)
        #expect(s.longest == 3)
    }

    @Test func endsYesterdayStillCounts() {
        let s = Streaks.compute(days: ["2026-10-09", "2026-10-10", "2026-10-11"], today: "2026-10-12")
        #expect(s.current == 3 && s.longest == 3)
    }

    @Test func endsTwoDaysAgoIsBroken() {
        let s = Streaks.compute(days: ["2026-10-08", "2026-10-09", "2026-10-10"], today: "2026-10-12")
        #expect(s.current == 0)
        #expect(s.longest == 3)
    }

    @Test func runsCrossMonthAndYearAndLeapDay() {
        let s = Streaks.compute(days: ["2023-12-31", "2024-01-01", "2024-02-28", "2024-02-29", "2024-03-01"], today: "2024-03-01")
        #expect(s.current == 3 && s.longest == 3)
    }

    @Test func duplicateDaysCountOnce() {
        let s = Streaks.compute(days: ["2026-10-11", "2026-10-11", "2026-10-12"], today: "2026-10-12")
        #expect(s.current == 2)
    }

    @Test func dayNumbers() {
        #expect(Streaks.dayNumber("1970-01-01") == 0)
        #expect(Streaks.dayNumber("2000-03-01") == 11_017)
        #expect(Streaks.dayNumber("nope") == nil)
    }

    @Test func localDayUsesTheGivenZone() throws {
        let instant = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09 08:53:20 UTC
        #expect(Streaks.localDay(for: instant, in: try #require(TimeZone(identifier: "UTC"))) == "2025-10-09")
        #expect(Streaks.localDay(for: instant, in: try #require(TimeZone(identifier: "Pacific/Auckland"))) == "2025-10-09")
        #expect(Streaks.localDay(for: instant, in: try #require(TimeZone(identifier: "Pacific/Honolulu"))) == "2025-10-08")
    }
}
