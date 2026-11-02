import Foundation
import MouthtypeCore

extension Notification.Name {
    /// A local action counter went up, so the trophy shelf should look again. Carries nothing.
    static let achievementCounterChanged = Notification.Name("com.codeswhat.mouthtype.achievementCounterChanged")
}

/// Adds to the local achievement counters. One integer per action, no text. Nothing here is on the dictation, paste or
/// hotkey path: callers are the voice edit and transform Accept buttons, the menu bar trick and the About credits.
@MainActor struct AchievementCounting {
    let store: AchievementStore
    let now: () -> Date
    let timeZone: () -> TimeZone
    let post: () -> Void

    init(
        defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { .current },
        post: @escaping () -> Void = { NotificationCenter.default.post(name: .achievementCounterChanged, object: nil) }
    ) {
        store = AchievementStore(defaults: defaults)
        self.now = now
        self.timeZone = timeZone
        self.post = post
    }

    /// Counts one completed action and tells the shelf. Returns false when Achievements is off.
    @discardableResult
    func record(_ counter: AchievementStore.Counter) -> Bool {
        let day = StatsTimeline.localDay(for: now(), in: timeZone())
        guard store.increment(counter, day: day) else { return false }
        post()
        return true
    }
}

extension AchievementCounting {
    /// Wraps `editor` so each replacement the app takes counts once for `counter`, while `condition` holds. A refused or stale
    /// replacement, a cancel and a failed read never count.
    func counting(
        _ editor: any SelectionEditing, as counter: AchievementStore.Counter, when condition: @escaping @MainActor () -> Bool = { true }
    ) -> ReplacementReportingEditor {
        ReplacementReportingEditor(base: editor) { if condition() { record(counter) } }
    }
}
