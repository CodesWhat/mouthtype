import Foundation
import MouthtypeCore
import Observation

/// The data behind the Stats and Records pages. Everything is rebuilt from the dictation log (nothing is stored), with
/// secure-field takes already excluded by the store query.
///
/// While active (window open on the Stats or Records page) the store is observed, so a finished take updates the numbers
/// without a reopen. Closing the window or leaving both pages stops the observation. The statistics are worked out on the
/// database reader queue or a detached task, never on the main thread, and a result that finishes after a deactivate is
/// dropped.
@MainActor @Observable final class StatsModel {
    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue, isActive { observe() } }
    }
    @ObservationIgnored private(set) var isActive: Bool
    @ObservationIgnored private var observation: TakesObservation?
    /// Bumped on every deactivate. A reload that started under an older value is dropped when it finishes.
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The off-main read behind `load()`. Replaceable so a test can make it slow.
    @ObservationIgnored var fetch: @Sendable (TranscriptStore, Date) throws -> StatsSnapshot = { store, now in
        try store.statsSnapshot(now: now)
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
        reloadTask?.cancel()
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
        reloadTask?.cancel()
        reloadTask = nil
        lifecycleGeneration += 1
    }

    /// Starts a tracked reload, only while active.
    func startReload() {
        guard isActive else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in await self?.load() }
    }

    /// Reads and computes off the main thread, then applies unless the model was deactivated meanwhile.
    func load() async {
        guard let store else { apply(nil, failure: "Stats are unavailable."); return }
        let read = fetch
        let generation = lifecycleGeneration
        do {
            let snapshot = try await Task.detached { try read(store, Date()) }.value
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            apply(snapshot, failure: nil)
        } catch {
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            apply(nil, failure: error.localizedDescription)
        }
    }

    private func observe() {
        observation?.cancel()
        observation = nil
        guard let store else { return }
        let generation = lifecycleGeneration
        observation = store.observeStats(onError: { error in
            Log.app.error("stats observation failed: \(error.localizedDescription, privacy: .public)")
        }, onChange: { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, self.isActive, generation == self.lifecycleGeneration else { return }
                self.apply(snapshot, failure: nil)
            }
        })
    }

    private func apply(_ snapshot: StatsSnapshot?, failure: String?) {
        self.snapshot = snapshot
        error = failure
    }
}
