import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct StatsEngineTests {
    private func s(_ day: String, words: Int, ms: Int? = nil, t: Double = 0) -> DictationSample {
        DictationSample(day: day, startedAt: Date(timeIntervalSince1970: t), words: words, durationMs: ms)
    }

    @Test func emptyLogGivesZerosAndNoRecords() {
        let engine = StatsEngine(samples: [])
        let r = engine.report(today: "2026-10-18")
        #expect(r.wordsAllTime == 0 && r.wordsToday == 0 && r.wordsThisWeek == 0)
        #expect(r.averageWPM == nil && r.bestWPM == nil && r.biggestDay == nil && r.longestDictation == nil)
        #expect(r.currentStreakDays == 0 && r.longestStreakDays == 0 && r.minutesSaved == 0)
        #expect(engine.records() == ArcadeRecords())
        #expect(engine.dailyWords(from: "2026-10-01", to: "2026-10-03").map(\.words) == [0, 0, 0])
    }

    @Test func todayWeekAndAllTimeUseTheStoredLocalDay() {
        let engine = StatsEngine(samples: [
            s("2026-10-18", words: 10), s("2026-10-18", words: 5), s("2026-10-12", words: 7),
            s("2026-10-11", words: 100), s("2026-09-01", words: 1),
        ])
        let r = engine.report(today: "2026-10-18")
        #expect(r.wordsToday == 15)
        #expect(r.wordsThisWeek == 22) // Oct 12...18; Oct 11 is the 8th day back
        #expect(r.wordsAllTime == 123)
    }

    @Test func dailyWordsZeroFillsAcrossMonthAndLeapDay() {
        let engine = StatsEngine(samples: [s("2028-02-29", words: 4), s("2028-03-01", words: 6)])
        let days = engine.dailyWords(from: "2028-02-28", to: "2028-03-02")
        #expect(days.map(\.day) == ["2028-02-28", "2028-02-29", "2028-03-01", "2028-03-02"])
        #expect(days.map(\.words) == [0, 4, 6, 0])
        #expect(engine.dailyWords(from: "2028-03-02", to: "2028-02-28").isEmpty)
        #expect(engine.dailyWords(from: "bad", to: "2028-02-28").isEmpty)
    }

    @Test func dayStringRoundTripsDayNumber() {
        for day in ["1970-01-01", "1999-12-31", "2000-02-29", "2026-10-18", "2100-03-01"] {
            #expect(StatsEngine.dayString(Streaks.dayNumber(day)!) == day)
        }
    }

    @Test func wpmIsWordsOverSpeakingTimeAndIgnoresShortOrImplausibleSamples() {
        let engine = StatsEngine(samples: [
            s("2026-10-18", words: 60, ms: 30_000),   // 120 wpm
            s("2026-10-18", words: 30, ms: 30_000),   // 60 wpm
            s("2026-10-18", words: 3, ms: 3_000),     // too few words
            s("2026-10-18", words: 50, ms: 2_000),    // too short
            s("2026-10-18", words: 500, ms: 10_000),  // 3000 wpm, bad timing
            s("2026-10-18", words: 40, ms: nil),      // no duration
        ])
        let r = engine.report(today: "2026-10-18")
        #expect(r.bestWPM == 120)
        #expect(r.averageWPM == 90) // 90 words over 1 minute
    }

    @Test func streaksCurrentAndLongest() {
        let engine = StatsEngine(samples: [
            s("2026-10-01", words: 1), s("2026-10-02", words: 1), s("2026-10-03", words: 1), s("2026-10-04", words: 1),
            s("2026-10-17", words: 1), s("2026-10-18", words: 1),
        ])
        let r = engine.report(today: "2026-10-18")
        #expect(r.currentStreakDays == 2 && r.longestStreakDays == 4)
        // Last active yesterday still counts; two days back does not.
        #expect(engine.report(today: "2026-10-19").currentStreakDays == 2)
        #expect(engine.report(today: "2026-10-20").currentStreakDays == 0)
    }

    @Test func recordsCarryTheDateTheyWereSet() {
        let engine = StatsEngine(samples: [
            s("2026-10-01", words: 20, ms: 20_000, t: 1), s("2026-10-02", words: 20, ms: 20_000, t: 2),
            s("2026-10-03", words: 80, ms: 40_000, t: 3), // 120 wpm, the biggest day and the longest dictation
            s("2026-10-04", words: 5, ms: 5_000, t: 4),
            s("2026-10-10", words: 80, ms: 40_000, t: 5), // ties on every count; the earlier one keeps it
        ])
        let rec = engine.records()
        #expect(rec.wpm == Record(value: 120, setOn: "2026-10-03"))
        #expect(rec.biggestDay == Record(value: 80, setOn: "2026-10-03"))
        #expect(rec.longestStreak == Record(value: 4, setOn: "2026-10-04"))
        #expect(rec.longestDictation == Record(value: LongestDictation(words: 80, durationMs: 40_000, day: "2026-10-03"), setOn: "2026-10-03"))
    }

    @Test func timeSavedComparesTypingToSpeakingAndNeverGoesNegative() {
        // 400 words at 40 wpm is 10 minutes of typing; speaking them took 2.
        let r = StatsEngine(samples: [s("2026-10-18", words: 400, ms: 120_000)]).report(today: "2026-10-18")
        #expect(abs(r.minutesSaved - 8) < 0.0001 && r.typingWPM == 40)
        let faster = StatsEngine(samples: [s("2026-10-18", words: 400, ms: 120_000)], typingWPM: 200).report(today: "2026-10-18")
        #expect(faster.minutesSaved == 0)
        #expect(StatsEngine(samples: [s("2026-10-18", words: 400, ms: nil)]).report(today: "2026-10-18").minutesSaved == 0)
        #expect(StatsEngine(samples: [], typingWPM: -5).report(today: "2026-10-18").typingWPM == 40)
    }

    @Test func malformedDaysAndEmptyDictationsAreDropped() {
        let engine = StatsEngine(samples: [s("nope", words: 9), s("2026-10-18", words: 0), s("2026-10-18", words: 3)])
        #expect(engine.report(today: "2026-10-18").wordsAllTime == 3)
    }

    @Test func rebuildsFromTheStoredLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("m.sqlite"))
        let utc = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_791_806_400) // 2026-10-12 12:00 UTC
        for (offset, words) in [(0.0, 60), (86_400, 30)] {
            let id = try store.begin(DictationStart(startedAt: noon.addingTimeInterval(offset), timeZone: utc))
            try store.recordCapture(id, CaptureRecord(audioMs: 30_000, voicedMs: 30_000))
            try store.recordInsertion(id, InsertionRecord(finalText: Array(repeating: "w", count: words).joined(separator: " ")))
        }
        let r = try store.statsEngine().report(today: "2026-10-13")
        #expect(r.wordsAllTime == 90 && r.wordsToday == 30 && r.currentStreakDays == 2)
        #expect(r.bestWPM == 120 && r.averageWPM == 90)
    }
}
