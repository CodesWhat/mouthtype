import Foundation
import MouthtypeCore
import Observation

/// The data behind the trophy shelf on Stats. Worked out from the stats snapshot plus a few small SQL facts, off the main thread
/// and off the dictation path: it only runs when the Stats page has a new snapshot, and not at all while Achievements is off.
/// Everything stays in UserDefaults on this Mac.
@MainActor @Observable final class AchievementModel {
    /// Empty while Achievements is off, or until the first evaluation finishes.
    private(set) var entries: [AchievementShelfEntry] = []
    private(set) var isEnabled: Bool
    private(set) var isShelfHidden: Bool
    @ObservationIgnored private let store: AchievementStore
    /// The in-window toast for new earns. Present always; it does nothing while Achievements is off.
    @ObservationIgnored let toasts: AchievementToastCenter
    /// Bumped on every refresh, so a slower earlier result never overwrites a newer one.
    @ObservationIgnored private var generation = 0
    /// The last SQL read and what it was read for. The extras only move when a take, a voice edit or a transform does, so the
    /// same key means the same answer and the queries are skipped.
    @ObservationIgnored private var cache: (key: ExtrasKey, extras: AchievementExtras)?

    private struct ExtrasKey: Equatable {
        var dictationCount: Int
        var voiceEdits: Int
        var transforms: Int
        /// The store's write revision, for changes that leave the take count alone (a remembered correction accepted, a snippet).
        var revision: Int
    }

    init(defaults: UserDefaults = .standard) {
        store = AchievementStore(defaults: defaults)
        toasts = AchievementToastCenter(store: store)
        isEnabled = store.isEnabled
        isShelfHidden = store.isShelfHidden
    }

    var defaults: UserDefaults { store.defaults }

    var hasNew: Bool { entries.contains(where: \.isNew) }

    var earnedCount: Int { entries.filter { if case .earned = $0.state { true } else { false } }.count }

    func setEnabled(_ value: Bool) {
        store.setEnabled(value)
        isEnabled = value
        if !value {
            generation += 1
            cache = nil
            entries = []
            toasts.reset()
        }
    }

    func setShelfHidden(_ value: Bool) {
        store.setShelfHidden(value)
        isShelfHidden = value
    }

    /// New earns stop being new once the shelf has been on screen.
    /// A collapsed shelf has not shown them, so they stay new until it has been seen expanded.
    func shelfSeen() {
        guard isEnabled, !isShelfHidden else { return }
        store.markAllSeen()
        toasts.shelfSeen(entries.filter(\.isNew).map(\.id))
        entries = entries.map {
            var entry = $0; entry.isNew = false; return entry
        }
    }

    /// Evaluates against `snapshot` and records what is newly earned. `loadExtras` runs off the main thread and is not called at
    /// all while Achievements is off. A failed read keeps the shelf as it was.
    func refresh(
        snapshot: StatsSnapshot, now: Date, timeZone: TimeZone, revision: Int = 0, loadExtras: @escaping @Sendable (Bool) throws -> AchievementExtras
    ) async {
        guard isEnabled else { return }
        generation += 1
        let ticket = generation
        let calibrated = TypingBaselinePreference.isAccepted(store.defaults)
        do {
            let counters = store.counters
            let key = ExtrasKey(
                dictationCount: snapshot.report.dictationCount, voiceEdits: counters.voiceEdits, transforms: counters.transforms,
                revision: revision)
            var extras: AchievementExtras
            if let cache, cache.key == key {
                extras = cache.extras
                extras.calibrated = calibrated
            } else {
                extras = try await OffPool.run { try loadExtras(calibrated) }
            }
            guard ticket == generation, isEnabled, !Task.isCancelled else { return }
            cache = (key, extras)
            extras.counters = counters
            let statuses = AchievementEngine.evaluate(AchievementInput(snapshot: snapshot, extras: extras))
            store.apply(statuses, today: StatsTimeline.localDay(for: now, in: timeZone))
            entries = AchievementEngine.shelf(statuses, store: store)
            toasts.ingest(entries)
        } catch {
            Log.app.error("achievements read failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
