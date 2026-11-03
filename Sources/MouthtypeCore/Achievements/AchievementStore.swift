import Foundation

/// Where earned trophies live: a few small UserDefaults values on this Mac. Nothing leaves the machine and nothing is ever
/// removed, so a cleared history or a clock change cannot revoke a trophy.
public struct AchievementStore {
    public static let enabledKey = "achievements.enabled"
    public static let shelfHiddenKey = "achievements.shelfHidden"
    public static let earnedKey = "achievements.earned"
    public static let approximateKey = "achievements.approximate"
    public static let seenKey = "achievements.seen"
    public static let backfilledKey = "achievements.backfilled"
    public static let toastedKey = "achievements.toasted"
    public static let lastToastKey = "achievements.lastToast"
    public static let backfillSummaryKey = "achievements.backfillSummary"
    public static let catchUpKey = "achievements.catchUp"

    /// The local counters behind the craft trophies. Each is one integer that only goes up. They hold no
    /// text, and they start counting from install: nothing in the log says how many voice edits happened before.
    public enum Counter: String, CaseIterable, Sendable {
        case voiceEdits, transforms

        public var key: String { "achievements.count.\(rawValue)" }
        /// The counts a trophy is waiting on, so the day each was reached is kept.
        var milestones: Set<Int> { self == .voiceEdits ? [1, 25] : [1] }
    }

    public static let counterDaysKey = "achievements.countDays"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Default on. Off turns the shelf off and the engine does no work.
    public var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    /// Turning it back on after it was off arms a catch-up: the first evaluation records whatever was earned meanwhile as seen,
    /// the same as the backfill, so the engine being idle never turns into a toast.
    public func setEnabled(_ value: Bool) {
        if value && !isEnabled { defaults.set(true, forKey: Self.catchUpKey) }
        defaults.set(value, forKey: Self.enabledKey)
    }

    public var isShelfHidden: Bool { defaults.bool(forKey: Self.shelfHiddenKey) }
    public func setShelfHidden(_ value: Bool) { defaults.set(value, forKey: Self.shelfHiddenKey) }

    /// Trophy id to the local day it was earned (`YYYY-MM-DD`).
    public var earned: [String: String] { defaults.dictionary(forKey: Self.earnedKey) as? [String: String] ?? [:] }
    /// Earned ids whose day is only the day they were found, shown as "Earned before trophies".
    public var approximate: Set<String> { Set(defaults.stringArray(forKey: Self.approximateKey) ?? []) }
    public var seen: Set<String> { Set(defaults.stringArray(forKey: Self.seenKey) ?? []) }
    public var isBackfilled: Bool { defaults.bool(forKey: Self.backfilledKey) }

    // MARK: Counters

    public func count(_ counter: Counter) -> Int { max(0, defaults.integer(forKey: counter.key)) }

    /// Adds one and returns true. Does nothing while Achievements is off, so the engine stays idle. `day` is the local day,
    /// kept for the counts a trophy waits on.
    @discardableResult
    public func increment(_ counter: Counter, day: String) -> Bool {
        guard isEnabled else { return false }
        let next = count(counter) &+ 1
        guard next > 0 else { return false }
        defaults.set(next, forKey: counter.key)
        if counter.milestones.contains(next) {
            var days = counterDays
            days["\(counter.rawValue):\(next)"] = day
            defaults.set(days, forKey: Self.counterDaysKey)
        }
        return true
    }

    /// `voiceEdits:25` to the local day that count was reached.
    public var counterDays: [String: String] { defaults.dictionary(forKey: Self.counterDaysKey) as? [String: String] ?? [:] }

    /// The counters as the engine reads them.
    public var counters: AchievementCounters {
        AchievementCounters(
            voiceEdits: count(.voiceEdits), transforms: count(.transforms), days: counterDays)
    }

    /// Records what `statuses` says is earned and was not before, and returns those ids. The first run is the backfill: whatever
    /// the history already earned is written as seen, with its real day when the data gives one and `today` (flagged
    /// approximate) when it does not. Later runs write new earns unseen, except the first run after Achievements was switched back on, which is silent like the backfill. Running twice with the same data records nothing.
    @discardableResult
    public func apply(_ statuses: [AchievementStatus], today: String) -> [String] {
        var earned = self.earned
        var approximate = self.approximate
        var seen = self.seen
        let backfill = !isBackfilled
        let catchUp = defaults.bool(forKey: Self.catchUpKey)
        var added: [String] = []
        for status in statuses {
            guard case .earned(let day) = status.state, earned[status.id] == nil else { continue }
            earned[status.id] = day ?? today
            if day == nil { approximate.insert(status.id) }
            if backfill || catchUp { seen.insert(status.id) }
            added.append(status.id)
        }
        if !added.isEmpty {
            defaults.set(earned, forKey: Self.earnedKey)
            defaults.set(approximate.sorted(), forKey: Self.approximateKey)
            defaults.set(seen.sorted(), forKey: Self.seenKey)
        }
        if catchUp { defaults.removeObject(forKey: Self.catchUpKey) }
        if backfill {
            defaults.set(true, forKey: Self.backfilledKey)
            // One summary toast, the first time Stats is open after the upgrade.
            if !added.isEmpty { defaults.set(added.count, forKey: Self.backfillSummaryKey) }
        }
        return added
    }

    /// Everything earned so far counts as seen, so its New tag goes away.
    public func markAllSeen() {
        let ids = Set(earned.keys)
        guard !ids.isSubset(of: seen) else { return }
        defaults.set(ids.union(seen).sorted(), forKey: Self.seenKey)
    }

    // MARK: Toast bookkeeping

    /// Earned ids the in-window toast has already announced, so a relaunch never announces one twice.
    public var toasted: Set<String> { Set(defaults.stringArray(forKey: Self.toastedKey) ?? []) }
    public func markToasted(_ ids: [String]) {
        defaults.set(toasted.union(ids).sorted(), forKey: Self.toastedKey)
    }

    /// When the last toast was shown, for the ten minute gap between toasts.
    public var lastToast: Date? {
        defaults.object(forKey: Self.lastToastKey) is Double ? Date(timeIntervalSince1970: defaults.double(forKey: Self.lastToastKey)) : nil
    }
    public func setLastToast(_ date: Date) { defaults.set(date.timeIntervalSince1970, forKey: Self.lastToastKey) }

    /// How many trophies the backfill found, until the one summary toast has been shown. Zero when there is nothing to show.
    public var pendingBackfillSummary: Int { defaults.integer(forKey: Self.backfillSummaryKey) }
    public func clearBackfillSummary() { defaults.removeObject(forKey: Self.backfillSummaryKey) }
}
