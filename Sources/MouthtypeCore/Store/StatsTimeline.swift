import Foundation

/// One take on today's tape: when it started, how many words it produced, and whether it left a transcript.
public struct TodayTake: Equatable, Sendable {
    public var startedAt: Date
    /// Seconds since local midnight in the zone the take happened in (the log's `utc_offset_s`), 0..<86400.
    public var secondsIntoDay: Int
    public var words: Int
    public var durationMs: Int?
    public var appName: String?

    /// False for a take whose audio was saved but which produced no transcript.
    public var hasTranscript: Bool { words > 0 }

    public init(startedAt: Date, secondsIntoDay: Int, words: Int, durationMs: Int?, appName: String?) {
        self.startedAt = startedAt
        self.secondsIntoDay = secondsIntoDay
        self.words = words
        self.durationMs = durationMs
        self.appName = appName
    }
}

/// Time-of-day numbers behind the Stats page: the hour buckets, today's tape and the streak dots.
public enum StatsTimeline {
    public static let hoursPerDay = 24
    /// The "Your day" chart looks at this many local days ending today.
    public static let hourWindowDays = 30

    /// Seconds since local midnight for a take, using the offset stored with it so a later time zone change never moves it.
    public static func secondsIntoDay(startedAt: Date, utcOffsetSeconds: Int) -> Int {
        let local = Int(startedAt.timeIntervalSince1970.rounded(.down)) + utcOffsetSeconds
        return ((local % 86_400) + 86_400) % 86_400
    }

    /// Seconds since local midnight for `date` in `timeZone`.
    public static func secondsIntoDay(of date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3_600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// The local day (`YYYY-MM-DD`) for `date` in `timeZone`.
    public static func localDay(for date: Date, in timeZone: TimeZone) -> String { Streaks.localDay(for: date, in: timeZone) }

    public static func hour(startedAt: Date, utcOffsetSeconds: Int) -> Int {
        secondsIntoDay(startedAt: startedAt, utcOffsetSeconds: utcOffsetSeconds) / 3_600
    }

    /// Stable order for the tape: by local time of day (what it plots), then by the take's own numbers so equal starts never
    /// swap between code paths.
    static func sorted(_ takes: [TodayTake]) -> [TodayTake] {
        takes.sorted {
            ($0.secondsIntoDay, $0.startedAt, $0.words, $0.durationMs ?? -1, $0.appName ?? "")
                < ($1.secondsIntoDay, $1.startedAt, $1.words, $1.durationMs ?? -1, $1.appName ?? "")
        }
    }

    /// The busiest hour (0...23), the earliest on a tie. Nil when nothing was dictated.
    public static func peakHour(_ hourly: [Int]) -> Int? {
        var best: Int?
        for (hour, words) in hourly.enumerated() where words > (best.map { hourly[$0] } ?? 0) { best = hour }
        return best
    }

    /// Which of the daily dots are lit for the current streak. `daily` ends today. A streak that hasn't been extended yet today
    /// still counts, so the run ends at yesterday and today's dot stays dark until the first take.
    public static func streakLit(daily: [DailyWords], currentStreak: Int) -> [Bool] {
        guard !daily.isEmpty, currentStreak > 0 else { return Array(repeating: false, count: daily.count) }
        let end = (daily.last?.words ?? 0) > 0 ? daily.count - 1 : daily.count - 2
        guard end >= 0 else { return Array(repeating: false, count: daily.count) }
        let start = end - currentStreak + 1
        return daily.indices.map { $0 >= start && $0 <= end }
    }
}

/// The readout under today's tape.
public struct TodaySummary: Equatable, Sendable {
    public var takes: Int
    public var words: Int
    public var speakingMs: Int
    /// Typing the same words at `typingWPM` minus speaking them, over takes with a logged duration. Never negative.
    public var minutesAvoided: Double

    public init(takes: [TodayTake], typingWPM: Double = StatsEngine.defaultTypingWPM) {
        let wpm = typingWPM > 0 ? typingWPM : StatsEngine.defaultTypingWPM
        let timed = takes.filter { ($0.durationMs ?? 0) > 0 }
        self.takes = takes.count
        words = takes.reduce(0) { $0 + $1.words }
        speakingMs = takes.reduce(0) { $0 + ($1.durationMs ?? 0) }
        let timedWords = timed.reduce(0) { $0 + $1.words }
        let timedMs = timed.reduce(0) { $0 + ($1.durationMs ?? 0) }
        minutesAvoided = max(0, Double(timedWords) / wpm - Double(timedMs) / 60_000)
    }
}
