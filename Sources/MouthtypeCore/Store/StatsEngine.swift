import Foundation

/// One finished dictation, reduced to the numbers the stats need. No text is carried.
public struct DictationSample: Equatable, Sendable {
    /// `YYYY-MM-DD` in the zone the dictation happened in (the log's `local_day`), so day boundaries never move
    /// when the Mac changes time zone later.
    public var day: String
    public var startedAt: Date
    public var words: Int
    /// Speaking time: voiced audio when the log has it, otherwise the whole recording. Nil when neither was logged.
    public var durationMs: Int?
    /// The offset the take was logged with, for its time of day.
    public var utcOffsetSeconds: Int
    public var appName: String?

    public init(day: String, startedAt: Date, words: Int, durationMs: Int?, utcOffsetSeconds: Int = 0, appName: String? = nil) {
        self.day = day
        self.startedAt = startedAt
        self.words = words
        self.durationMs = durationMs
        self.utcOffsetSeconds = utcOffsetSeconds
        self.appName = appName
    }
}

public struct DailyWords: Equatable, Sendable {
    public var day: String
    public var words: Int

    public init(day: String, words: Int) {
        self.day = day
        self.words = words
    }
}

public struct LongestDictation: Equatable, Sendable {
    public var words: Int
    public var durationMs: Int?
    public var day: String

    public init(words: Int, durationMs: Int?, day: String) {
        self.words = words
        self.durationMs = durationMs
        self.day = day
    }
}

public struct StatsReport: Equatable, Sendable {
    public var wordsToday: Int
    /// The trailing seven local days including today.
    public var wordsThisWeek: Int
    public var wordsAllTime: Int
    public var dictationCount: Int
    public var averageWPM: Double?
    public var bestWPM: Double?
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    public var biggestDay: DailyWords?
    public var longestDictation: LongestDictation?
    /// Minutes saved against typing the same words at `typingWPM`, never negative.
    public var minutesSaved: Double
    public var typingWPM: Double
    /// Total speaking time of the takes with a logged duration, in minutes.
    public var speakingMinutes: Double
    /// The earliest local day with words (`YYYY-MM-DD`).
    public var firstDay: String?

    public init(
        wordsToday: Int, wordsThisWeek: Int, wordsAllTime: Int, dictationCount: Int, averageWPM: Double?, bestWPM: Double?,
        currentStreakDays: Int, longestStreakDays: Int, biggestDay: DailyWords?, longestDictation: LongestDictation?,
        minutesSaved: Double, typingWPM: Double, speakingMinutes: Double = 0, firstDay: String? = nil
    ) {
        self.wordsToday = wordsToday
        self.wordsThisWeek = wordsThisWeek
        self.wordsAllTime = wordsAllTime
        self.dictationCount = dictationCount
        self.averageWPM = averageWPM
        self.bestWPM = bestWPM
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.biggestDay = biggestDay
        self.longestDictation = longestDictation
        self.minutesSaved = minutesSaved
        self.typingWPM = typingWPM
        self.speakingMinutes = speakingMinutes
        self.firstDay = firstDay
    }
}

public struct Record<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    /// The local day (`YYYY-MM-DD`) the record was set.
    public var setOn: String

    public init(value: Value, setOn: String) {
        self.value = value
        self.setOn = setOn
    }
}

public struct ArcadeRecords: Equatable, Sendable {
    public var wpm: Record<Double>?
    public var biggestDay: Record<Int>?
    public var longestStreak: Record<Int>?
    public var longestDictation: Record<LongestDictation>?

    public init(
        wpm: Record<Double>? = nil, biggestDay: Record<Int>? = nil, longestStreak: Record<Int>? = nil,
        longestDictation: Record<LongestDictation>? = nil
    ) {
        self.wpm = wpm
        self.biggestDay = biggestDay
        self.longestStreak = longestStreak
        self.longestDictation = longestDictation
    }
}

/// What the Stats and Records pages show, worked out from the log in one go.
public struct StatsSnapshot: Equatable, Sendable {
    public static let dailyWindowDays = 30

    public var report: StatsReport
    public var records: ArcadeRecords
    /// The last `dailyWindowDays` local days ending today, zero-filled. Empty when there is no history.
    public var daily: [DailyWords]
    /// Words by local hour of day (24 buckets) over the last `StatsTimeline.hourWindowDays` days ending today.
    public var hourlyWords: [Int]
    /// Today's takes in start order. From the SQL path this includes takes with saved audio and no transcript; the
    /// sample path only sees takes that produced words.
    public var todayTakes: [TodayTake]

    public var hasHistory: Bool { report.dictationCount > 0 }

    public init(
        report: StatsReport, records: ArcadeRecords, daily: [DailyWords],
        hourlyWords: [Int] = Array(repeating: 0, count: StatsTimeline.hoursPerDay), todayTakes: [TodayTake] = []
    ) {
        self.report = report
        self.records = records
        self.daily = daily
        self.hourlyWords = hourlyWords
        self.todayTakes = todayTakes
    }

    public static func make(
        samples: [DictationSample], now: Date, timeZone: TimeZone = .current,
        typingWPM: Double = StatsEngine.defaultTypingWPM
    ) -> StatsSnapshot {
        let engine = StatsEngine(samples: samples, typingWPM: typingWPM)
        let today = Streaks.localDay(for: now, in: timeZone)
        let report = engine.report(today: today)
        let daily =
            report.dictationCount == 0
            ? []
            : Streaks.dayNumber(today).map {
                engine.dailyWords(from: StatsEngine.dayString($0 - (dailyWindowDays - 1)), to: today)
            } ?? []
        let timeline = engine.timeline(today: today)
        return StatsSnapshot(
            report: report, records: engine.records(), daily: daily,
            hourlyWords: timeline.hourly, todayTakes: timeline.takes)
    }
}

/// The log reduced by SQL: one row of sums per local day, and the two records that need a row-level ordering.
struct StatsAggregates: Sendable {
    struct Day: Sendable {
        var day: String
        var count: Int
        var words: Int
        /// Words and speaking milliseconds of the takes that count toward WPM.
        var ratedWords: Int
        var ratedMs: Int
        /// Words and speaking milliseconds of the takes with a logged duration, for time saved.
        var timedWords: Int
        var timedMs: Int
    }

    var days: [Day]
    /// The highest qualifying rate, earliest take on a tie, and the day it was set.
    var bestWPM: (rate: Double, day: String)?
    var longest: LongestDictation?
    var hourlyWords = [Int](repeating: 0, count: StatsTimeline.hoursPerDay)
    var todayTakes: [TodayTake] = []
}

extension StatsSnapshot {
    /// The same numbers as `make(samples:)`, from SQL aggregates instead of every sample.
    static func make(
        aggregates: StatsAggregates, now: Date, timeZone: TimeZone = .current,
        typingWPM: Double = StatsEngine.defaultTypingWPM
    ) -> StatsSnapshot {
        let typingWPM = typingWPM > 0 ? typingWPM : StatsEngine.defaultTypingWPM
        let days = aggregates.days.filter { $0.words > 0 }
            .compactMap { d in Streaks.dayNumber(d.day).map { (d, $0) } }
            .sorted { $0.1 < $1.1 }
        let totals = days.map { (day: $0.0.day, number: $0.1, words: $0.0.words) }
        let today = Streaks.localDay(for: now, in: timeZone)
        let todayNumber = Streaks.dayNumber(today)

        let wordsToday = totals.first { $0.day == today }?.words ?? 0
        let week = todayNumber.map { t in totals.filter { $0.number > t - 7 && $0.number <= t }.reduce(0) { $0 + $1.words } } ?? 0
        let all = totals.reduce(0) { $0 + $1.words }
        let count = days.reduce(0) { $0 + $1.0.count }
        let ratedWords = days.reduce(0) { $0 + $1.0.ratedWords }
        let ratedMs = days.reduce(0) { $0 + $1.0.ratedMs }
        let average = ratedMs > 0 ? Double(ratedWords) / (Double(ratedMs) / 60_000) : nil
        let streaks = Streaks.compute(days: totals.map(\.day), today: today)
        let typingMinutes = Double(days.reduce(0) { $0 + $1.0.timedWords }) / typingWPM
        let speakingMinutes = Double(days.reduce(0) { $0 + $1.0.timedMs }) / 60_000

        let biggest = StatsEngine.biggestDay(totals)
        let report = StatsReport(
            wordsToday: wordsToday, wordsThisWeek: week, wordsAllTime: all, dictationCount: count,
            averageWPM: average, bestWPM: aggregates.bestWPM?.rate,
            currentStreakDays: streaks.current, longestStreakDays: streaks.longest,
            biggestDay: biggest, longestDictation: aggregates.longest,
            minutesSaved: max(0, typingMinutes - speakingMinutes), typingWPM: typingWPM,
            speakingMinutes: speakingMinutes, firstDay: days.first?.0.day
        )
        let streak = StatsEngine.longestStreak(totals.map(\.number))
        let records = ArcadeRecords(
            wpm: aggregates.bestWPM.map { Record(value: $0.rate, setOn: $0.day) },
            biggestDay: biggest.map { Record(value: $0.words, setOn: $0.day) },
            longestStreak: streak.map { Record(value: $0.length, setOn: StatsEngine.dayString($0.reachedOn)) },
            longestDictation: aggregates.longest.map { Record(value: $0, setOn: $0.day) }
        )
        var daily: [DailyWords] = []
        if count > 0, let t = todayNumber {
            var byNumber: [Int: Int] = [:]
            for d in totals { byNumber[d.number] = d.words }
            daily = ((t - (dailyWindowDays - 1))...t).map { DailyWords(day: StatsEngine.dayString($0), words: byNumber[$0] ?? 0) }
        }
        return StatsSnapshot(
            report: report, records: records, daily: daily,
            hourlyWords: aggregates.hourlyWords, todayTakes: StatsTimeline.sorted(aggregates.todayTakes))
    }
}

/// Pure statistics over the dictation log. Everything here is rebuilt from samples on demand; nothing is stored,
/// so deleting or re-importing the log can never leave a stale record behind.
///
/// WPM: words divided by speaking minutes. Speaking time is `voiced_ms`, falling back to `audio_ms`. A dictation
/// only counts toward WPM when it has at least `minWPMWords` words and `minWPMDurationMs` of speech, and a rate above
/// `maxPlausibleWPM` is treated as a bad timing and ignored. The average is total words over total speaking time of
/// the qualifying dictations (not a mean of rates, so a short fragment can't skew it). Best WPM is the highest
/// single qualifying dictation.
///
/// Days: a "day" is the log's stored `local_day`, grouped as-is. A streak is consecutive days with at least one word;
/// the current streak survives until the end of the day after the last active day, matching the menu's rule.
public struct StatsEngine: Sendable {
    public static let defaultTypingWPM = 40.0
    public static let minWPMWords = 5
    public static let minWPMDurationMs = 3_000
    public static let maxPlausibleWPM = 400.0

    typealias DayTotal = (day: String, number: Int, words: Int)

    private let samples: [DictationSample]
    private let typingWPM: Double

    public init(samples: [DictationSample], typingWPM: Double = StatsEngine.defaultTypingWPM) {
        self.samples = samples.filter { $0.words > 0 && Streaks.dayNumber($0.day) != nil }
        self.typingWPM = typingWPM > 0 ? typingWPM : Self.defaultTypingWPM
    }

    private func wpm(_ s: DictationSample) -> Double? {
        guard s.words >= Self.minWPMWords, let ms = s.durationMs, ms >= Self.minWPMDurationMs else { return nil }
        // Multiply first so the arithmetic matches the SQL aggregates bit for bit.
        let rate = Double(s.words) * 60_000 / Double(ms)
        return rate <= Self.maxPlausibleWPM ? rate : nil
    }

    /// Words per local day, ascending by day. Days without words are absent.
    private var totalsByDay: [DayTotal] {
        var byDay: [String: Int] = [:]
        for s in samples { byDay[s.day, default: 0] += s.words }
        return byDay.compactMap { day, words in Streaks.dayNumber(day).map { (day: day, number: $0, words: words) } }
            .sorted { $0.number < $1.number }
    }

    /// Every day from `from` through `to` inclusive (`YYYY-MM-DD`), zero-filled. Empty if either bound is malformed
    /// or `to` is before `from`.
    public func dailyWords(from: String, to: String) -> [DailyWords] {
        guard let start = Streaks.dayNumber(from), let end = Streaks.dayNumber(to), start <= end else { return [] }
        var byNumber: [Int: Int] = [:]
        for d in totalsByDay { byNumber[d.number] = d.words }
        return (start...end).map { DailyWords(day: Self.dayString($0), words: byNumber[$0] ?? 0) }
    }

    public func report(today: String) -> StatsReport {
        let days = totalsByDay
        let wordsToday = days.first { $0.day == today }?.words ?? 0
        var week = 0
        if let t = Streaks.dayNumber(today) {
            week = days.filter { $0.number > t - 7 && $0.number <= t }.reduce(0) { $0 + $1.words }
        }
        let all = samples.reduce(0) { $0 + $1.words }

        let rated = samples.compactMap { s in wpm(s).map { (sample: s, rate: $0) } }
        let ratedWords = rated.reduce(0) { $0 + $1.sample.words }
        let ratedMs = rated.reduce(0) { $0 + ($1.sample.durationMs ?? 0) }
        let average = ratedMs > 0 ? Double(ratedWords) / (Double(ratedMs) / 60_000) : nil

        let streaks = Streaks.compute(days: days.map(\.day), today: today)

        // Time saved: typing the same words minus speaking them. Dictations with no logged duration are left out of
        // both sides rather than counted as free.
        let timed = samples.filter { ($0.durationMs ?? 0) > 0 }
        let typingMinutes = Double(timed.reduce(0) { $0 + $1.words }) / typingWPM
        let speakingMinutes = Double(timed.reduce(0) { $0 + ($1.durationMs ?? 0) }) / 60_000

        return StatsReport(
            wordsToday: wordsToday, wordsThisWeek: week, wordsAllTime: all, dictationCount: samples.count,
            averageWPM: average, bestWPM: rated.map(\.rate).max(),
            currentStreakDays: streaks.current, longestStreakDays: streaks.longest,
            biggestDay: Self.biggestDay(days), longestDictation: longestDictation(),
            minutesSaved: max(0, typingMinutes - speakingMinutes), typingWPM: typingWPM,
            speakingMinutes: speakingMinutes, firstDay: days.first?.day
        )
    }

    /// Words by local hour over the trailing `hourWindowDays` days ending `today`, and today's takes in order.
    func timeline(today: String) -> (hourly: [Int], takes: [TodayTake]) {
        var hourly = [Int](repeating: 0, count: StatsTimeline.hoursPerDay)
        var takes: [TodayTake] = []
        guard let t = Streaks.dayNumber(today) else { return (hourly, takes) }
        for s in samples {
            guard let n = Streaks.dayNumber(s.day) else { continue }
            if n > t - StatsTimeline.hourWindowDays && n <= t {
                hourly[StatsTimeline.hour(startedAt: s.startedAt, utcOffsetSeconds: s.utcOffsetSeconds)] += s.words
            }
            if s.day == today {
                takes.append(
                    TodayTake(
                        startedAt: s.startedAt,
                        secondsIntoDay: StatsTimeline.secondsIntoDay(startedAt: s.startedAt, utcOffsetSeconds: s.utcOffsetSeconds),
                        words: s.words, durationMs: s.durationMs, appName: s.appName))
            }
        }
        return (hourly, StatsTimeline.sorted(takes))
    }

    public func records() -> ArcadeRecords {
        var bestRate: (sample: DictationSample, rate: Double)?
        for s in samples {
            guard let rate = wpm(s) else { continue }
            if bestRate == nil || rate > bestRate!.rate || (rate == bestRate!.rate && s.startedAt < bestRate!.sample.startedAt) {
                bestRate = (s, rate)
            }
        }
        let days = totalsByDay
        let streak = Self.longestStreak(days.map(\.number))
        let longest = longestDictation()
        return ArcadeRecords(
            wpm: bestRate.map { Record(value: $0.rate, setOn: $0.sample.day) },
            biggestDay: Self.biggestDay(days).map { Record(value: $0.words, setOn: $0.day) },
            longestStreak: streak.map { Record(value: $0.length, setOn: Self.dayString($0.reachedOn)) },
            longestDictation: longest.map { Record(value: $0, setOn: $0.day) }
        )
    }

    // MARK: Internals

    /// Most words in one day; the earliest day wins a tie.
    static func biggestDay(_ days: [DayTotal]) -> DailyWords? {
        var best: DayTotal?
        for d in days where d.words > (best?.words ?? 0) { best = d }
        return best.map { DailyWords(day: $0.day, words: $0.words) }
    }

    /// Most words in one dictation; the earliest wins a tie.
    private func longestDictation() -> LongestDictation? {
        var best: DictationSample?
        for s in samples {
            if best == nil || s.words > best!.words || (s.words == best!.words && s.startedAt < best!.startedAt) { best = s }
        }
        return best.map { LongestDictation(words: $0.words, durationMs: $0.durationMs, day: $0.day) }
    }

    /// The longest run of consecutive day numbers (ascending, distinct) and the day it first reached that length.
    static func longestStreak(_ numbers: [Int]) -> (length: Int, reachedOn: Int)? {
        guard !numbers.isEmpty else { return nil }
        var best = (length: 1, reachedOn: numbers[0])
        var run = 1
        for i in numbers.indices.dropFirst() {
            run = numbers[i] == numbers[i - 1] + 1 ? run + 1 : 1
            if run > best.length { best = (run, numbers[i]) }
        }
        return best
    }

    /// Inverse of `Streaks.dayNumber`: days since 1970-01-01 to `YYYY-MM-DD`.
    static func dayString(_ number: Int) -> String {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
