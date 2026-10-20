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
/// The store is observed, so a finished take, saved audio, or expired or purged audio updates the page without a reopen.
/// Reads run off the main thread and only `limit` rows are ever fetched.
@MainActor @Observable final class HomeLogModel {
    static let limit = 50

    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue { observe() } }
    }
    @ObservationIgnored var saved: @MainActor () async throws -> [RecoverableDictation]
    /// Whether Recover may run right now. Read through `recoverEnabled`, which the page watches.
    @ObservationIgnored var canRecover: @MainActor () -> Bool {
        didSet { refreshRecoverability() }
    }
    @ObservationIgnored var recoverTake: @MainActor (RecoverableDictation) -> Void
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private var textTakes: [HomeTake] = []
    @ObservationIgnored private var recordings: [RecoverableDictation] = []
    @ObservationIgnored private var observation: TakesObservation?
    @ObservationIgnored private var savedTask: Task<Void, Never>?
    @ObservationIgnored private var trackingGeneration = 0
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
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.store = store
        self.saved = saved
        self.canRecover = canRecover
        self.recoverTake = recover
        self.copyText = copy
        refreshRecoverability()
        observe()
    }

    isolated deinit {
        observation?.cancel()
        savedTask?.cancel()
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
        await loadText()
        await refreshSaved()
    }

    /// Fetches the newest takes off the main thread.
    func loadText() async {
        guard let store else { apply(nil, failure: "Recent dictations are unavailable."); return }
        let limit = Self.limit
        do {
            let records = try await Task.detached { try store.recentTakes(limit: limit) }.value
            apply(records, failure: nil)
        } catch {
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
        textTakes = records.map(Self.takes(from:)) ?? []
        error = failure
        rebuild()
        refreshRecoverability()
    }

    private func refreshSaved() async {
        do {
            attach(try await saved())
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
