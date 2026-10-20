import AppKit
import Foundation
import MouthtypeCore
import Observation

/// The data behind the Stats and Records pages. Everything is rebuilt from the dictation log (nothing is stored), with
/// secure-field takes already excluded by the store query.
///
/// While active (window open on the Stats or Records page) the store is observed, so a finished take updates the numbers
/// without a reopen. Closing the window or leaving both pages stops the observation. The statistics are worked out on the
/// database reader queue or a detached task, never on the main thread. The observation's first value is the initial
/// read, so activating starts no second read. A result that finishes after a deactivate, or after a newer one was
/// applied, is dropped. The date-dependent numbers (today, this week, the daily window, streaks) are recomputed at local
/// midnight and on a day, clock, time zone or wake change.
@MainActor @Observable final class StatsModel {
    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue, isActive { observe() } }
    }
    @ObservationIgnored private(set) var isActive: Bool
    @ObservationIgnored private var observation: TakesObservation?
    /// Bumped on every deactivate. A reload that started under an older value is dropped when it finishes.
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var rolloverTask: Task<Void, Never>?
    @ObservationIgnored private var rolloverObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Tickets for results: a result applies only if no newer one has been applied.
    @ObservationIgnored private var issued = 0
    @ObservationIgnored private var applied = 0
    /// The model's clock and zone. Replaceable so a test can cross midnight.
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    /// Read afresh for every query and midnight schedule, so a time zone change takes effect on the next refresh.
    @ObservationIgnored var timeZoneProvider: @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }
    /// Waits out a delay. Replaceable so a test doesn't wait for real midnight.
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The off-main read behind `load()`. Replaceable so a test can make it slow.
    @ObservationIgnored var fetch: @Sendable (TranscriptStore, Date, TimeZone) throws -> StatsSnapshot = { store, now, zone in
        try store.statsSnapshot(now: now, timeZone: zone)
    }
    /// Starts the store observation. Replaceable so a test can make it fail.
    @ObservationIgnored var startObservation: (TranscriptStore, TimeZone, @escaping @Sendable () -> Date,
                                               @escaping @Sendable (Error) -> Void,
                                               @escaping @Sendable (StatsSnapshot) -> Void) -> TakesObservation? = {
        store, zone, clock, onError, onChange in
        store.observeStats(timeZone: zone, now: clock, onError: onError, onChange: onChange)
    }
    /// Nil until the first load finishes.
    private(set) var snapshot: StatsSnapshot?
    private(set) var error: String?

    init(store: TranscriptStore? = nil, observing: Bool = true) {
        self.isActive = observing
        self.store = store
        if observing { observe() }
    }

    isolated deinit {
        observation?.cancel()
        rolloverTask?.cancel()
        removeRolloverObservers()
    }

    /// Starts watching the store. Delivers the current numbers right away, so a reopened page begins from a fresh read.
    func activate() {
        guard !isActive else { return }
        isActive = true
        observe()
    }

    /// Stops watching the store and drops any read in flight.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        observation?.cancel()
        observation = nil
        rolloverTask?.cancel()
        rolloverTask = nil
        removeRolloverObservers()
        lifecycleGeneration += 1
    }

    /// Reads and computes off the main thread, then applies unless the model was deactivated meanwhile.
    func load() async {
        guard let store else { apply(nil, failure: "Stats are unavailable."); return }
        let read = fetch
        let (instant, zone) = (now(), timeZoneProvider())
        let generation = lifecycleGeneration
        issued += 1
        let ticket = issued
        do {
            let snapshot = try await Task.detached { try read(store, instant, zone) }.value
            guard generation == lifecycleGeneration, ticket > applied, !Task.isCancelled else { return }
            applied = ticket
            apply(snapshot, failure: nil)
        } catch {
            guard generation == lifecycleGeneration, ticket > applied, !Task.isCancelled else { return }
            applied = ticket
            apply(nil, failure: error.localizedDescription)
        }
    }

    private func observe() {
        observation?.cancel()
        observation = nil
        rolloverTask?.cancel()
        rolloverTask = nil
        removeRolloverObservers()
        guard let store else {
            if isActive { apply(nil, failure: "Stats are unavailable.") }
            return
        }
        let generation = lifecycleGeneration
        let clock = now
        scheduleRollover()
        observation = startObservation(store, timeZoneProvider(), clock, { [weak self] error in
            Log.app.error("stats observation failed: \(error.localizedDescription, privacy: .public)")
            let message = error.localizedDescription
            MainActor.assumeIsolated {
                guard let self, self.isActive, generation == self.lifecycleGeneration else { return }
                self.apply(nil, failure: message)
            }
        }, { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, self.isActive, generation == self.lifecycleGeneration else { return }
                // Newer than any read already in flight, so a slower earlier one can't overwrite it.
                self.issued += 1
                self.applied = self.issued
                self.apply(snapshot, failure: nil)
            }
        })
    }

    private func apply(_ snapshot: StatsSnapshot?, failure: String?) {
        self.snapshot = snapshot
        error = failure
    }

    // MARK: Day rollover

    /// Restarts the observation, which re-reads at once with the current date.
    private func refreshForNewDay() {
        guard isActive, store != nil else { return }
        observe()
    }

    private func removeRolloverObservers() {
        for (center, token) in rolloverObservers { center.removeObserver(token) }
        rolloverObservers = []
    }

    /// Waits for the next local midnight, then refreshes, and repeats. A day change, clock change, time zone change or
    /// wake from sleep refreshes too.
    private func scheduleRollover() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshForNewDay() }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            rolloverObservers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: refresh)))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        rolloverObservers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)))

        rolloverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let step = self?.untilNextMidnight() else { return }
                do { try await step.sleep(step.delay) } catch { return }
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.refreshForNewDay()
                return  // refreshForNewDay re-observes, which schedules the next midnight
            }
        }
    }

    private func untilNextMidnight() -> (delay: Duration, sleep: @Sendable (Duration) async throws -> Void) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let current = now()
        let midnight = calendar.nextDate(after: current, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                         matchingPolicy: .nextTime) ?? current.addingTimeInterval(3_600)
        return (.seconds(max(1, midnight.timeIntervalSince(current))), sleep)
    }
}
