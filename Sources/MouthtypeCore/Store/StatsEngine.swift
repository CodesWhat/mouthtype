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

    public init(day: String, startedAt: Date, words: Int, durationMs: Int?) {
        self.day = day
        self.startedAt = startedAt
        self.words = words
        self.durationMs = durationMs
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

    public init(
        wordsToday: Int, wordsThisWeek: Int, wordsAllTime: Int, dictationCount: Int, averageWPM: Double?, bestWPM: Double?,
        currentStreakDays: Int, longestStreakDays: Int, biggestDay: DailyWords?, longestDictation: LongestDictation?,
        minutesSaved: Double, typingWPM: Double
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

    private typealias DayTotal = (day: String, number: Int, words: Int)

    private let samples: [DictationSample]
    private let typingWPM: Double

    public init(samples: [DictationSample], typingWPM: Double = StatsEngine.defaultTypingWPM) {
        self.samples = samples.filter { $0.words > 0 && Streaks.dayNumber($0.day) != nil }
        self.typingWPM = typingWPM > 0 ? typingWPM : Self.defaultTypingWPM
    }

    private func wpm(_ s: DictationSample) -> Double? {
        guard s.words >= Self.minWPMWords, let ms = s.durationMs, ms >= Self.minWPMDurationMs else { return nil }
        let rate = Double(s.words) / (Double(ms) / 60_000)
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
            biggestDay: biggestDay(days), longestDictation: longestDictation(),
            minutesSaved: max(0, typingMinutes - speakingMinutes), typingWPM: typingWPM
        )
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
        let streak = longestStreak(days.map(\.number))
        let longest = longestDictation()
        return ArcadeRecords(
            wpm: bestRate.map { Record(value: $0.rate, setOn: $0.sample.day) },
            biggestDay: biggestDay(days).map { Record(value: $0.words, setOn: $0.day) },
            longestStreak: streak.map { Record(value: $0.length, setOn: Self.dayString($0.reachedOn)) },
            longestDictation: longest.map { Record(value: $0, setOn: $0.day) }
        )
    }

    // MARK: Internals

    /// Most words in one day; the earliest day wins a tie.
    private func biggestDay(_ days: [DayTotal]) -> DailyWords? {
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
    private func longestStreak(_ numbers: [Int]) -> (length: Int, reachedOn: Int)? {
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
