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

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Default on. Off turns the shelf off and the engine does no work.
    public var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    public func setEnabled(_ value: Bool) { defaults.set(value, forKey: Self.enabledKey) }

    public var isShelfHidden: Bool { defaults.bool(forKey: Self.shelfHiddenKey) }
    public func setShelfHidden(_ value: Bool) { defaults.set(value, forKey: Self.shelfHiddenKey) }

    /// Trophy id to the local day it was earned (`YYYY-MM-DD`).
    public var earned: [String: String] { defaults.dictionary(forKey: Self.earnedKey) as? [String: String] ?? [:] }
    /// Earned ids whose day is only the day they were found, shown as "Earned before trophies".
    public var approximate: Set<String> { Set(defaults.stringArray(forKey: Self.approximateKey) ?? []) }
    public var seen: Set<String> { Set(defaults.stringArray(forKey: Self.seenKey) ?? []) }
    public var isBackfilled: Bool { defaults.bool(forKey: Self.backfilledKey) }

    /// Records what `statuses` says is earned and was not before, and returns those ids. The first run is the backfill: whatever
    /// the history already earned is written as seen, with its real day when the data gives one and `today` (flagged
    /// approximate) when it does not. Later runs write new earns unseen. Running twice with the same data records nothing.
    @discardableResult
    public func apply(_ statuses: [AchievementStatus], today: String) -> [String] {
        var earned = self.earned
        var approximate = self.approximate
        var seen = self.seen
        let backfill = !isBackfilled
        var added: [String] = []
        for status in statuses {
            guard case .earned(let day) = status.state, earned[status.id] == nil else { continue }
            earned[status.id] = day ?? today
            if day == nil { approximate.insert(status.id) }
            if backfill { seen.insert(status.id) }
            added.append(status.id)
        }
        if !added.isEmpty {
            defaults.set(earned, forKey: Self.earnedKey)
            defaults.set(approximate.sorted(), forKey: Self.approximateKey)
            defaults.set(seen.sorted(), forKey: Self.seenKey)
        }
        if backfill { defaults.set(true, forKey: Self.backfilledKey) }
        return added
    }

    /// Everything earned so far counts as seen, so its New tag goes away.
    public func markAllSeen() {
        let ids = Set(earned.keys)
        guard !ids.isSubset(of: seen) else { return }
        defaults.set(ids.union(seen).sorted(), forKey: Self.seenKey)
    }
}
