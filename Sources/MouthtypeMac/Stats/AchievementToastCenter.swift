import AppKit
import MouthtypeCore
import Observation

/// Runs the trophy toast: feeds the scheduler, owns the one toast on screen and its six second life, and does the side effects
/// (the existing cue, one VoiceOver announcement). Everything it reads from the app comes through an injected closure, and
/// `autoSchedule: false` keeps tests free of timers.
@MainActor @Observable final class AchievementToastCenter {
    private(set) var current: AchievementToast?
    /// Earns are waiting behind the gate: the Stats sidebar item shows a dot.
    private(set) var hasQueued = false
    private(set) var isPaused = false

    // Inputs, set by the window and the app.
    var windowIsKey = false { didSet { if windowIsKey != oldValue { poll() } } }
    var statsOpen = false { didSet { if statsOpen != oldValue { poll() } } }
    @ObservationIgnored var isDictationBusy: @MainActor () -> Bool = { false }
    @ObservationIgnored var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @ObservationIgnored var playCue: @MainActor () -> Void = {}
    @ObservationIgnored var announce: @MainActor (String) -> Void = AchievementToastCenter.postAnnouncement
    /// Opens the Stats shelf; set by the window.
    @ObservationIgnored var openShelf: @MainActor () -> Void = {}

    @ObservationIgnored private var scheduler: AchievementToastScheduler
    @ObservationIgnored private let store: AchievementStore
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let autoSchedule: Bool
    @ObservationIgnored private var lifeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private(set) var deadline: Date?
    @ObservationIgnored private(set) var pausedRemaining: TimeInterval?

    init(store: AchievementStore, clock: @escaping @MainActor () -> Date = { Date() }, autoSchedule: Bool = true) {
        self.store = store
        self.clock = clock
        self.autoSchedule = autoSchedule
        scheduler = AchievementToastScheduler(lastShown: store.lastToast, backfillCount: store.pendingBackfillSummary)
    }

    // MARK: Feeding

    /// Takes the shelf as it stands after an evaluation. Earns not yet seen on the shelf and not yet announced queue up, oldest
    /// first, and the backfill summary is picked up if one is pending.
    func ingest(_ entries: [AchievementShelfEntry]) {
        let toasted = store.toasted
        let pending = entries.compactMap { entry -> (AchievementToastEarn, String)? in
            guard entry.isNew, !toasted.contains(entry.id), case .earned(let day) = entry.state else { return nil }
            return (AchievementToastEarn(id: entry.id, name: entry.name, copy: entry.copy, tier: entry.tier), day ?? "")
        }
        .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
        scheduler.enqueue(pending)
        scheduler.queueBackfill(count: store.pendingBackfillSummary)
        poll()
    }

    /// The shelf has been on screen: what it showed needs no toast.
    func shelfSeen(_ ids: [String]) {
        scheduler.drop(ids: Set(ids))
        sync()
    }

    /// Achievements turned off: nothing queued, nothing showing.
    func reset() {
        scheduler.clear()
        dismiss()
        pollTask?.cancel()
        sync()
    }

    // MARK: Presenting

    var context: AchievementToastContext {
        AchievementToastContext(
            now: clock(), windowIsKey: windowIsKey, dictationBusy: isDictationBusy(), statsOpen: statsOpen,
            reduceMotion: reduceMotion(), soundsEnabled: SoundPreference.isEnabled(store.defaults))
    }

    /// Shows the next toast if the gate is open; otherwise waits for the moment that opens it.
    func poll() {
        pollTask?.cancel()
        sync()
        guard current == nil, !scheduler.isEmpty else { return }
        let context = self.context
        switch scheduler.readiness(context) {
        case .ready:
            guard let toast = scheduler.poll(context) else { return }
            present(toast, at: context.now)
        case .windowNotKey:
            break
        case .busy:
            wake(after: 2)
        case .cooldown(let until):
            wake(after: max(1, until.timeIntervalSince(context.now)))
        }
        sync()
    }

    private func present(_ toast: AchievementToast, at now: Date) {
        current = toast
        isPaused = false
        pausedRemaining = nil
        store.setLastToast(now)
        if toast.kind == .earned { store.markToasted(toast.ids) } else { store.clearBackfillSummary() }
        if toast.playsSound { playCue() }
        announce(toast.accessibilityLabel)
        startLife(AchievementToastScheduler.duration)
        sync()
    }

    func dismiss() {
        lifeTask?.cancel()
        lifeTask = nil
        deadline = nil
        pausedRemaining = nil
        isPaused = false
        guard current != nil else { return }
        current = nil
        poll()
    }

    /// Click on the toast: open the shelf and close it.
    func open() {
        guard current != nil else { return }
        openShelf()
        dismiss()
    }

    /// Hover or focus holds the toast; leaving lets it run out its remaining time.
    func setPaused(_ paused: Bool) {
        guard current != nil, paused != isPaused else { return }
        if paused {
            pausedRemaining = max(0, (deadline ?? clock()).timeIntervalSince(clock()))
            lifeTask?.cancel()
            lifeTask = nil
            isPaused = true
        } else {
            isPaused = false
            let remaining = pausedRemaining ?? AchievementToastScheduler.duration
            pausedRemaining = nil
            startLife(remaining)
        }
    }

    /// The toast ran out its time.
    func lifeEnded() { dismiss() }

    /// Fraction of the six seconds left, for the bar.
    func fractionLeft(at date: Date) -> Double {
        let remaining = isPaused ? pausedRemaining ?? 0 : max(0, (deadline ?? date).timeIntervalSince(date))
        return min(1, remaining / AchievementToastScheduler.duration)
    }

    private func startLife(_ seconds: TimeInterval) {
        lifeTask?.cancel()
        deadline = clock().addingTimeInterval(seconds)
        guard autoSchedule else { return }
        lifeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lifeEnded()
        }
    }

    private func wake(after seconds: TimeInterval) {
        guard autoSchedule else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.poll()
        }
    }

    private func sync() {
        let queued = scheduler.hasQueued
        if hasQueued != queued { hasQueued = queued }
    }

    /// One polite VoiceOver announcement. The window is key whenever this runs, so focus is not taken from anything.
    static func postAnnouncement(_ text: String) {
        guard let element = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
