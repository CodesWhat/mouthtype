import AppKit
import MouthtypeCore
import Observation

/// One row of the Home log. `text` is nil for a take that never produced a transcript but still has audio on disk.
struct HomeTake: Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var text: String?
    var appName: String?
    var recoverable: RecoverableDictation?
}

/// The data behind the Home page: recent dictations from the transcript store, newest first, plus the saved audio
/// each one can be recovered from. Secure-field takes never show, matching the Recent Dictations menu.
///
/// While active (window open on the Home page) the store is observed, so a finished take, saved audio, or expired or
/// purged audio updates the page without a reopen. Closing the window stops the observation; reopening starts it fresh.
/// Reads run off the main thread and only `limit` rows are ever fetched.
@MainActor @Observable final class HomeLogModel {
    static let limit = 50

    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue, isActive { observe() } }
    }
    @ObservationIgnored var saved: @MainActor () async throws -> [RecoverableDictation]
    /// Whether Recover may run right now. Read through `recoverEnabled`, which the page watches.
    @ObservationIgnored var canRecover: @MainActor () -> Bool {
        didSet { refreshRecoverability() }
    }
    /// Kept audio behind finished takes, from each row's own audio path. Runs off the main thread.
    @ObservationIgnored var completedAudio: @MainActor ([DictationRecord]) async -> [RecoverableDictation] = { _ in [] }
    @ObservationIgnored var recoverTake: @MainActor (RecoverableDictation) -> Void
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private var records: [DictationRecord] = []
    @ObservationIgnored private var savedGeneration = 0
    @ObservationIgnored private(set) var isActive: Bool
    @ObservationIgnored private var textTakes: [HomeTake] = []
    @ObservationIgnored private var recordings: [RecoverableDictation] = []
    @ObservationIgnored private var observation: TakesObservation?
    @ObservationIgnored private var savedTask: Task<Void, Never>?
    @ObservationIgnored private var trackingGeneration = 0
    /// Bumped on every deactivate. A reload that started under an older value is dropped when it finishes.
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The off-main read behind `loadText()`. Replaceable so a test can make it slow.
    @ObservationIgnored var fetchRecent: @Sendable (TranscriptStore, Int) throws -> [DictationRecord] = { store, limit in
        try store.recentTakes(limit: limit)
    }
    private(set) var takes: [HomeTake] = []
    private(set) var error: String?
    private(set) var lastCopiedID: String?
    /// Observable copy of `canRecover()`. Recomputed under observation tracking, so changes to any observable state the
    /// closure reads (dictation phase, engine state, file transcription) redraw the buttons, and `refreshRecoverability()`
    /// covers the state that is not observable.
    private(set) var recoverEnabled = false

    init(store: TranscriptStore? = nil,
         saved: @escaping @MainActor () async throws -> [RecoverableDictation] = { [] },
         canRecover: @escaping @MainActor () -> Bool = { true },
         recover: @escaping @MainActor (RecoverableDictation) -> Void = { _ in },
         copy: @escaping @MainActor (String) -> Void = { text in
             HomeLogModel.guardedCopy(text, to: SystemPasteboard(.general))
         },
         observing: Bool = true) {
        self.isActive = observing
        self.store = store
        self.saved = saved
        self.canRecover = canRecover
        self.recoverTake = recover
        self.copyText = copy
        refreshRecoverability()
        if observing { observe() }
    }

    isolated deinit {
        observation?.cancel()
        savedTask?.cancel()
        reloadTask?.cancel()
    }

    /// Copy keeps the text out of clipboard-manager history, like the app's other copies.
    static func guardedCopy(_ text: String, to pasteboard: PasteboardAccess) {
        pasteboard.write(text, markers: PasteboardSession.concealedMarkers)
    }

    /// Starts watching the store. Delivers the current rows right away, so a reopened page begins from a fresh fetch.
    func activate() {
        guard !isActive else { return }
        isActive = true
        observe()
    }

    /// Stops watching the store and drops any audio scan in flight.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        observation?.cancel()
        observation = nil
        savedTask?.cancel()
        savedTask = nil
        savedGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        lifecycleGeneration += 1
    }

    /// Starts a tracked reload, only while active. Deactivating cancels it and drops whatever it was about to apply.
    func startReload() {
        guard isActive else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in await self?.reload() }
    }

    /// Recomputes `recoverEnabled` and re-arms tracking of whatever observable state `canRecover` reads.
    func refreshRecoverability() {
        trackingGeneration += 1
        let generation = trackingGeneration
        let enabled = withObservationTracking { canRecover() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingGeneration == generation else { return }
                self.refreshRecoverability()
            }
        }
        if recoverEnabled != enabled { recoverEnabled = enabled }
    }

    /// Reloads the text, then attaches saved audio. The text shows first so a slow audio scan never blanks the page.
    func reload() async {
        let generation = lifecycleGeneration
        await loadText()
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        await refreshSaved()
    }

    /// Fetches the newest takes off the main thread.
    func loadText() async {
        guard let store else { apply(nil, failure: "Recent dictations are unavailable."); return }
        let limit = Self.limit
        let fetch = fetchRecent
        let generation = lifecycleGeneration
        do {
            let records = try await Task.detached { try fetch(store, limit) }.value
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            apply(records, failure: nil)
        } catch {
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            apply(nil, failure: error.localizedDescription)
        }
    }

    private func observe() {
        observation?.cancel()
        observation = nil
        guard let store else { return }
        observation = store.observeRecentTakes(limit: Self.limit, onError: { error in
            Log.app.error("home log observation failed: \(error.localizedDescription, privacy: .public)")
        }, onChange: { [weak self] records in
            MainActor.assumeIsolated {
                self?.apply(records, failure: nil)
                self?.savedTask?.cancel()
                self?.savedTask = Task { @MainActor [weak self] in await self?.refreshSaved() }
            }
        })
    }

    private func apply(_ records: [DictationRecord]?, failure: String?) {
        self.records = records ?? []
        textTakes = records.map(Self.takes(from:)) ?? []
        error = failure
        rebuild()
        refreshRecoverability()
    }

    /// Only the latest call applies: an older scan that finishes after a newer one started is dropped.
    private func refreshSaved() async {
        savedGeneration += 1
        let generation = savedGeneration
        let rows = records
        do {
            let unfinished = try await saved()
            let finished = await completedAudio(rows)
            guard generation == savedGeneration, !Task.isCancelled else { return }
            attach(unfinished + finished)
        } catch {
            Log.app.error("home saved recordings unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Newest first. Secure rows and blank transcripts are dropped.
    static func takes(from records: [DictationRecord]) -> [HomeTake] {
        records
            .filter { $0.isSecure != true && !($0.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
            .map { HomeTake(id: $0.id, startedAt: Date(timeIntervalSince1970: $0.startedAt), text: $0.finalText, appName: $0.appName) }
    }

    /// Saved audio joins its take by id. A saved recording with no transcript becomes its own take, in date order.
    func attach(_ found: [RecoverableDictation]) {
        recordings = found
        rebuild()
        refreshRecoverability()
    }

    private func rebuild() {
        var byID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = textTakes.map { take -> HomeTake in
            var take = take
            take.recoverable = byID.removeValue(forKey: take.id)
            return take
        }
        for recording in byID.values {
            merged.append(HomeTake(id: recording.id, startedAt: recording.startedAt, text: nil, appName: nil, recoverable: recording))
        }
        let next = Array(merged.sorted { $0.startedAt > $1.startedAt }.prefix(Self.limit))
        if next != takes { takes = next }
    }

    func copy(_ take: HomeTake) {
        guard let text = take.text else { return }
        copyText(text)
        lastCopiedID = take.id
    }

    func recover(_ take: HomeTake) {
        guard let recording = take.recoverable, canRecover() else { return }
        recoverTake(recording)
    }
}
