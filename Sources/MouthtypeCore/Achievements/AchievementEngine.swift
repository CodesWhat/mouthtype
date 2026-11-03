import Foundation

/// One tile on the shelf: a catalog entry with where it stands. Carries no text from the log.
public struct AchievementShelfEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var group: AchievementGroup
    public var tier: AchievementTier
    public var name: String
    public var copy: String
    public var state: AchievementState
    /// Earned, but the data could not say which day, so it is shown as earned before trophies.
    public var isApproximate: Bool
    /// Earned after the first backfill and not yet seen on the shelf.
    public var isNew: Bool

    public init(
        id: String, group: AchievementGroup, tier: AchievementTier, name: String, copy: String, state: AchievementState,
        isApproximate: Bool, isNew: Bool
    ) {
        self.id = id
        self.group = group
        self.tier = tier
        self.name = name
        self.copy = copy
        self.state = state
        self.isApproximate = isApproximate
        self.isNew = isNew
    }
}

/// Pure achievement logic. Reads a stats snapshot and a few extras, never the log itself.
public enum AchievementEngine {
    /// Where every entry stands right now, from the data alone. A hidden entry that is not earned says nothing about itself.
    public static func evaluate(_ input: AchievementInput, catalog: [AchievementDefinition] = AchievementCatalog.all) -> [AchievementStatus] {
        catalog.map { definition in
            let reading = definition.read(input)
            if reading.isEarned { return AchievementStatus(id: definition.id, state: .earned(day: reading.day)) }
            if definition.isHidden { return AchievementStatus(id: definition.id, state: .hidden) }
            return AchievementStatus(
                id: definition.id, state: .locked(AchievementProgress(current: reading.value, target: reading.target, line: reading.line)))
        }
    }

    /// The shelf: fresh statuses overlaid with what was already earned, so history that is deleted or a clock that moves never
    /// takes a trophy back. The stored day wins over a recomputed one.
    public static func shelf(
        _ statuses: [AchievementStatus], store: AchievementStore, catalog: [AchievementDefinition] = AchievementCatalog.all
    ) -> [AchievementShelfEntry] {
        let earned = store.earned, approximate = store.approximate, seen = store.seen
        let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return catalog.map { definition in
            let stored = earned[definition.id]
            let state: AchievementState
            if let stored {
                state = .earned(day: approximate.contains(definition.id) ? nil : stored)
            } else {
                state = byID[definition.id]?.state ?? (definition.isHidden ? .hidden : .locked(AchievementProgress(current: 0, target: 1, line: "")))
            }
            return AchievementShelfEntry(
                id: definition.id, group: definition.group, tier: definition.tier, name: definition.name, copy: definition.copy,
                state: state, isApproximate: stored != nil && approximate.contains(definition.id),
                isNew: stored != nil && !seen.contains(definition.id))
        }
    }
}
