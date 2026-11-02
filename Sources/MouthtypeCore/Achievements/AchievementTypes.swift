import Foundation

public enum AchievementTier: String, Sendable, Equatable, CaseIterable {
    case bronze, silver, gold
}

public enum AchievementGroup: Int, Sendable, Equatable, CaseIterable {
    case firstSteps, volume, streaks, speed, craft, hidden

    public var title: String {
        switch self {
        case .firstSteps: "First steps"
        case .volume: "Volume"
        case .streaks: "Streaks"
        case .speed: "Speed and time saved"
        case .craft: "Craft"
        case .hidden: "Hidden"
        }
    }
}

/// How many times each local action has completed, and the day the counts a trophy waits on were reached. Integers only.
public struct AchievementCounters: Equatable, Sendable {
    public var voiceEdits: Int
    public var transforms: Int
    public var mouthTricks: Int
    public var creditsViews: Int
    /// `voiceEdits:25` to a local day.
    public var days: [String: String]

    public init(voiceEdits: Int = 0, transforms: Int = 0, mouthTricks: Int = 0, creditsViews: Int = 0, days: [String: String] = [:]) {
        self.voiceEdits = voiceEdits
        self.transforms = transforms
        self.mouthTricks = mouthTricks
        self.creditsViews = creditsViews
        self.days = days
    }

    public func day(_ counter: AchievementStore.Counter, reaching count: Int) -> String? { days["\(counter.rawValue):\(count)"] }
}

/// What the engine needs beyond the stats snapshot: a few small facts read from the log by SQL. No text is ever carried, and
/// takes from secure fields are left out of every figure.
public struct AchievementExtras: Equatable, Sendable {
    /// One local day with words, for the cumulative and streak dates of a backfill.
    public struct Day: Equatable, Sendable {
        public var day: String
        public var takes: Int
        public var words: Int
        /// Words and speaking milliseconds of the takes with a logged duration, for time saved.
        public var timedWords: Int
        public var timedMs: Int

        public init(day: String, takes: Int, words: Int, timedWords: Int = 0, timedMs: Int = 0) {
            self.day = day
            self.takes = takes
            self.words = words
            self.timedWords = timedWords
            self.timedMs = timedMs
        }
    }

    /// Ascending by day, days with words only.
    public var days: [Day]
    public var distinctApps: Int
    /// The local day the third distinct app first appeared.
    public var thirdAppDay: String?
    public var handsFreeCount: Int
    public var handsFreeFirstDay: String?
    public var snippetCount: Int
    public var snippetTenthDay: String?
    public var rememberedCount: Int
    public var firstRememberedDay: String?
    /// The first local day with a take of 20 or more words that started between 00:00 and 04:00 local time.
    public var nightOwlDay: String?
    /// The longest single take by duration (the longest by words can be a different take), and its day.
    public var longestDurationMs: Int?
    public var longestDurationDay: String?
    /// An accepted typing calibration exists.
    public var calibrated: Bool
    /// Local action counts. Not in the log, so they start at install and are never backfilled.
    public var counters: AchievementCounters

    public init(
        days: [Day] = [], distinctApps: Int = 0, thirdAppDay: String? = nil, handsFreeCount: Int = 0,
        handsFreeFirstDay: String? = nil, snippetCount: Int = 0, snippetTenthDay: String? = nil, rememberedCount: Int = 0,
        firstRememberedDay: String? = nil, nightOwlDay: String? = nil, longestDurationMs: Int? = nil,
        longestDurationDay: String? = nil, calibrated: Bool = false,
        counters: AchievementCounters = AchievementCounters()
    ) {
        self.days = days
        self.distinctApps = distinctApps
        self.thirdAppDay = thirdAppDay
        self.handsFreeCount = handsFreeCount
        self.handsFreeFirstDay = handsFreeFirstDay
        self.snippetCount = snippetCount
        self.snippetTenthDay = snippetTenthDay
        self.rememberedCount = rememberedCount
        self.firstRememberedDay = firstRememberedDay
        self.nightOwlDay = nightOwlDay
        self.longestDurationMs = longestDurationMs
        self.longestDurationDay = longestDurationDay
        self.calibrated = calibrated
        self.counters = counters
    }
}

public struct AchievementInput: Sendable {
    public var report: StatsReport
    public var records: ArcadeRecords
    public var extras: AchievementExtras

    public init(report: StatsReport, records: ArcadeRecords, extras: AchievementExtras) {
        self.report = report
        self.records = records
        self.extras = extras
    }

    public init(snapshot: StatsSnapshot, extras: AchievementExtras) {
        self.init(report: snapshot.report, records: snapshot.records, extras: extras)
    }
}

/// One achievement's reading: how far along it is, and the day it was reached when it has been.
public struct AchievementReading: Sendable {
    public var value: Double
    public var target: Double
    /// The plain progress line shown while locked.
    public var line: String
    /// Only meaningful when `value >= target`. Nil when the data cannot say.
    public var day: String?

    public var isEarned: Bool { value >= target }
}

public struct AchievementDefinition: Sendable, Identifiable {
    public let id: String
    public let group: AchievementGroup
    public let tier: AchievementTier
    public let isHidden: Bool
    public let name: String
    public let copy: String
    public let read: @Sendable (AchievementInput) -> AchievementReading
}

public struct AchievementProgress: Equatable, Sendable {
    public var current: Double
    public var target: Double
    public var line: String

    public init(current: Double, target: Double, line: String) {
        self.current = current
        self.target = target
        self.line = line
    }

    public var fraction: Double { target > 0 ? min(1, max(0, current / target)) : 0 }
}

public enum AchievementState: Equatable, Sendable {
    /// `day` is nil when the data cannot say which day.
    case earned(day: String?)
    case locked(AchievementProgress)
    /// Not earned, and nothing about it is shown.
    case hidden
}

public struct AchievementStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var state: AchievementState

    public init(id: String, state: AchievementState) {
        self.id = id
        self.state = state
    }

    public var isEarned: Bool {
        if case .earned = state { return true }
        return false
    }
}
