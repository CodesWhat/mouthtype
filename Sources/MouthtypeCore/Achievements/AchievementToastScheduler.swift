import Foundation

/// One trophy waiting for its toast.
public struct AchievementToastEarn: Equatable, Sendable {
    public var id: String
    public var name: String
    public var copy: String
    public var tier: AchievementTier

    public init(id: String, name: String, copy: String, tier: AchievementTier) {
        self.id = id
        self.name = name
        self.copy = copy
        self.tier = tier
    }
}

/// What the scheduler needs to know about the moment, so it holds no clock and reads no app state itself.
public struct AchievementToastContext: Equatable, Sendable {
    public var now: Date
    /// The Mouthtype window is visible and key.
    public var windowIsKey: Bool
    /// A recording, a voice edit or a take being processed is in flight.
    public var dictationBusy: Bool
    /// The Stats page is the one showing.
    public var statsOpen: Bool
    public var reduceMotion: Bool
    public var soundsEnabled: Bool

    public init(
        now: Date, windowIsKey: Bool, dictationBusy: Bool = false, statsOpen: Bool = false, reduceMotion: Bool = false,
        soundsEnabled: Bool = true
    ) {
        self.now = now
        self.windowIsKey = windowIsKey
        self.dictationBusy = dictationBusy
        self.statsOpen = statsOpen
        self.reduceMotion = reduceMotion
        self.soundsEnabled = soundsEnabled
    }
}

/// A toast ready to draw: all the words, the cup, and how to present it.
public struct AchievementToast: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case earned, backfill }

    public var kind: Kind
    /// The trophies it announces, oldest first. Empty for the backfill summary.
    public var ids: [String]
    public var tier: AchievementTier
    /// The sprite on the cup; nil is the plain gold trophy.
    public var spriteID: String?
    public var kicker: String
    public var title: String
    public var body: String
    /// What VoiceOver reads, announced once when the toast appears.
    public var accessibilityLabel: String
    /// Slides in from below; false under Reduce Motion, where it appears in place.
    public var slides: Bool
    /// Plays the existing cue: only with the sounds toggle on.
    public var playsSound: Bool
    public var shownAt: Date

    public var id: String { kind == .backfill ? "backfill" : ids.joined(separator: ",") }
}

/// Decides when a trophy toast may appear. A pure value: the caller feeds it earns and asks `poll` at each moment that could
/// matter, and it answers with a toast or nothing. Nothing presents while the window is not key, while dictation is in
/// flight, or inside ten minutes of the last toast. Several queued earns collapse into one toast.
public struct AchievementToastScheduler: Equatable, Sendable {
    public static let cooldown: TimeInterval = 600
    public static let duration: TimeInterval = 6

    public enum Readiness: Equatable, Sendable {
        case ready
        case windowNotKey
        case busy
        /// A toast was shown inside the gap; the next may show at this date.
        case cooldown(until: Date)
    }

    public private(set) var queue: [AchievementToastEarn] = []
    /// Trophies the backfill found, waiting for the one summary toast.
    public private(set) var backfillCount = 0
    public private(set) var lastShown: Date?

    public init(lastShown: Date? = nil, backfillCount: Int = 0) {
        self.lastShown = lastShown
        self.backfillCount = max(0, backfillCount)
    }

    /// Something is queued behind the gate, so the Stats sidebar item shows its dot. The backfill summary sets no dot.
    public var hasQueued: Bool { !queue.isEmpty }
    public var isEmpty: Bool { queue.isEmpty && backfillCount == 0 }

    /// Adds earns the queue does not hold yet. Order is oldest first; the last is the newest.
    public mutating func enqueue(_ earns: [AchievementToastEarn]) {
        let held = Set(queue.map(\.id))
        queue += earns.filter { !held.contains($0.id) }
    }

    public mutating func queueBackfill(count: Int) { backfillCount = max(0, count) }

    /// Forgets queued earns, for trophies the user has already seen on the shelf.
    public mutating func drop(ids: Set<String>) { queue.removeAll { ids.contains($0.id) } }

    public mutating func clear() {
        queue = []
        backfillCount = 0
    }

    public func readiness(_ context: AchievementToastContext) -> Readiness {
        guard context.windowIsKey else { return .windowNotKey }
        guard !context.dictationBusy else { return .busy }
        if let lastShown {
            let until = lastShown.addingTimeInterval(Self.cooldown)
            if context.now < until { return .cooldown(until: until) }
        }
        return .ready
    }

    /// The toast to show now, if any. Showing it empties the queue it drew from and starts the ten minute gap.
    public mutating func poll(_ context: AchievementToastContext) -> AchievementToast? {
        guard !isEmpty, readiness(context) == .ready else { return nil }
        let slides = !context.reduceMotion
        if backfillCount > 0, context.statsOpen {
            let count = backfillCount
            backfillCount = 0
            lastShown = context.now
            let title = count == 1 ? "Found 1 trophy from your history." : "Found \(count) trophies from your history."
            let body = "Open the shelf to see them."
            return AchievementToast(
                kind: .backfill, ids: [], tier: .gold, spriteID: nil, kicker: "Trophies found", title: title, body: body,
                accessibilityLabel: "Trophies found. \(title) \(body)", slides: slides, playsSound: context.soundsEnabled,
                shownAt: context.now)
        }
        guard let newest = queue.last else { return nil }
        let earns = queue
        queue = []
        lastShown = context.now
        let others = earns.count - 1
        let title = others == 0 ? newest.name : "\(newest.name) and \(others) more"
        let body = others == 0 ? newest.copy : "Open Stats to see them all."
        let label =
            others == 0
            ? "Trophy unlocked, \(newest.name), \(newest.tier.rawValue). \(newest.copy)"
            : "Trophies unlocked, \(title). \(body)"
        return AchievementToast(
            kind: .earned, ids: earns.map(\.id), tier: newest.tier, spriteID: newest.id,
            kicker: others == 0 ? "Trophy unlocked" : "Trophies unlocked", title: title, body: body, accessibilityLabel: label,
            slides: slides, playsSound: context.soundsEnabled, shownAt: context.now)
    }
}
