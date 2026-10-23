import Foundation
import MouthtypeCore
import Observation

/// Dismissed suggestions, remembered next to dictionary.json so they stay gone. A dismissed suggestion comes back only
/// when its evidence count has doubled since the dismissal.
struct DismissedSuggestions: Codable, Equatable {
    static let currentVersion = 1
    var version = DismissedSuggestions.currentVersion
    /// Suggestion id to the evidence count when it was dismissed.
    var counts: [String: Int] = [:]

    static func url(besides dictionary: URL) -> URL {
        dictionary.deletingLastPathComponent().appendingPathComponent("dismissed-suggestions.json")
    }

    static func load(from url: URL) -> DismissedSuggestions {
        guard let data = try? Data(contentsOf: url),
            var saved = try? JSONDecoder().decode(DismissedSuggestions.self, from: data),
            saved.version == currentVersion
        else { return DismissedSuggestions() }
        saved.counts = saved.counts.filter { countRange.contains($0.value) }
        return saved
    }

    /// Counts outside this range can only come from a damaged file, so those entries are dropped on load.
    static let countRange = 0...1_000_000

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func hides(_ suggestion: SpellingSuggestion) -> Bool {
        guard let seen = counts[suggestion.id] else { return false }
        let doubled = seen.multipliedReportingOverflow(by: 2)
        let next = seen.addingReportingOverflow(1)
        let threshold = max(doubled.overflow ? Int.max : doubled.partialValue, next.overflow ? Int.max : next.partialValue)
        return suggestion.count < threshold
    }
}

/// The Suggestions section of Saved spellings: runs the suggester over the newest takes off the main thread and applies
/// accepted, removed and dismissed suggestions. Active only while the window is open, like `HomeLogModel`; a run that
/// started before a deactivate or a newer run is dropped when it finishes.
@MainActor @Observable final class SpellingSuggestionsModel {
    static let takeLimit = 1_000

    /// What the last Add or Remove did, so Undo can put it back.
    struct Undo: Equatable {
        enum Action: Equatable { case added([DictionaryRule]), removed([FileVocabulary.RemovedEntry]) }
        var message: String
        var action: Action
    }

    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue { lastRun = nil; if isActive { startReload() } } }
    }
    @ObservationIgnored private let vocabulary: FileVocabulary
    @ObservationIgnored private let dismissedURL: URL
    @ObservationIgnored var onRulesChanged: @MainActor () -> Void = {}
    @ObservationIgnored var fetchRecent: @Sendable (TranscriptStore, Int) throws -> [TakeRecord] = { store, limit in
        try store.recentTakes(limit: limit)
    }
    @ObservationIgnored var isKnownWord: @Sendable (String) -> Bool = { SystemWordChecker.shared.isKnown($0) }
    @ObservationIgnored private var dismissed: DismissedSuggestions
    @ObservationIgnored private var all: [SpellingSuggestion] = []
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var computeTask: Task<Computed?, Never>?
    /// The inputs the last finished run saw. An identical read (same take count, newest take and rules) reuses its result.
    @ObservationIgnored private var lastRun: Computed?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    struct Computed: Sendable {
        var records: [TakeRecord]
        var rules: [DictionaryRule]
        var found: [SpellingSuggestion]
    }

    private(set) var suggestions: [SpellingSuggestion] = []
    private(set) var undo: Undo?
    private(set) var error: String?

    init(vocabulary: FileVocabulary, store: TranscriptStore? = nil, dismissedURL: URL? = nil) {
        self.vocabulary = vocabulary
        self.store = store
        let url = dismissedURL ?? DismissedSuggestions.url(besides: vocabulary.url)
        self.dismissedURL = url
        dismissed = DismissedSuggestions.load(from: url)
    }

    isolated deinit {
        reloadTask?.cancel()
        computeTask?.cancel()
        undoTask?.cancel()
    }

    var confident: [SpellingSuggestion] { suggestions.filter { $0.confidence > Self.maybeThreshold } }
    var maybe: [SpellingSuggestion] { suggestions.filter { $0.confidence <= Self.maybeThreshold } }
    static let maybeThreshold = 0.5

    func activate() {
        guard !isActive else { return }
        isActive = true
        startReload()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        generation += 1
        reloadTask?.cancel()
        reloadTask = nil
        computeTask?.cancel()
        computeTask = nil
        clearUndo()
    }

    func startReload() {
        guard isActive else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in await self?.reload() }
    }

    /// Reads the takes and current rules off the main thread, then keeps what hasn't been dismissed.
    func reload() async {
        guard let store else { all = []; lastRun = nil; publish(); return }
        generation += 1
        let mine = generation
        let fetch = fetchRecent
        let vocabulary = vocabulary
        let limit = Self.takeLimit
        let isKnownWord = isKnownWord
        let previous = lastRun
        computeTask?.cancel()
        let work = Task.detached { () async -> Computed? in
            let records = try? await OffPool.run { try fetch(store, limit) }
            guard let records, let rules = try? vocabulary.allRules(), !Task.isCancelled else { return nil }
            if let previous, previous.records == records, previous.rules == rules {
                return previous
            }
            let found = SpellingSuggester.suggest(takes: Self.takes(from: records), rules: rules, isKnownWord: isKnownWord)
            return Task.isCancelled ? nil : Computed(records: records, rules: rules, found: found)
        }
        computeTask = work
        let computed = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard mine == generation, !Task.isCancelled, let computed else { return }
        lastRun = computed
        all = computed.found
        publish()
    }

    nonisolated static func takes(from records: [TakeRecord]) -> [SuggestionTake] {
        records.compactMap { record in
            guard record.isSecure != true, let raw = record.rawText, let final = record.finalText,
                !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let boosted =
                record.boostTermsAppliedJson
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return SuggestionTake(
                id: record.id, rawText: raw, finalText: final, boostTermsApplied: boosted,
                app: record.appName, date: Date(timeIntervalSince1970: record.startedAt),
                language: record.language.flatMap { DictationLanguage(code: $0) })
        }
    }

    private func publish() {
        let next = all.filter { !dismissed.hides($0) }
        if next != suggestions { suggestions = next }
    }

    /// Saves each heard form through the editor's save path. All or nothing: a failure rolls back what was added.
    func add(_ suggestion: SpellingSuggestion) {
        guard suggestion.kind != .removeHazard else { return }
        var added: [DictionaryRule] = []
        do {
            for heard in suggestion.heardForms {
                let rule = DictionaryRule(
                    heard: heard.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                    written: suggestion.written.trimmingCharacters(in: .whitespacesAndNewlines))
                try vocabulary.save(original: nil, rule: rule)
                added.append(rule)
            }
        } catch {
            for rule in added { _ = try? vocabulary.remove(rule) }
            self.error = error.localizedDescription
            return
        }
        finish(Undo(message: "Added \(suggestion.written).", action: .added(added)), dropping: suggestion)
    }

    /// Removes exactly the saved rules the suggestion was computed from (heard and written as stored), in one write. A
    /// rule the user has since changed is left alone and the suggestions are refreshed.
    func remove(_ suggestion: SpellingSuggestion) {
        guard suggestion.kind == .removeHazard, !suggestion.hazardRules.isEmpty else { return }
        do {
            let removed = try vocabulary.removeAll(suggestion.hazardRules)
            let label = suggestion.hazardRules.map(\.heard).joined(separator: ", ")
            finish(Undo(message: "Removed \(label).", action: .removed(removed)), dropping: suggestion)
        } catch FileVocabulary.WriteError.changed {
            error = "That spelling changed. Refreshing suggestions."
            startReload()
        } catch { self.error = error.localizedDescription }
    }

    func undoLast() {
        guard let undo else { return }
        do {
            switch undo.action {
            case .added(let rules):
                try vocabulary.removeAll(rules)
            case .removed(let entries):
                try vocabulary.restore(entries)
            }
            clearUndo()
            error = nil
            onRulesChanged()
            startReload()
        } catch FileVocabulary.WriteError.changed {
            clearUndo()
            error = "That spelling changed, so Undo left it alone. Refreshing suggestions."
            startReload()
        } catch FileVocabulary.WriteError.staleUndo {
            clearUndo()
            error = FileVocabulary.WriteError.staleUndo.errorDescription
            startReload()
        } catch { self.error = error.localizedDescription }
    }

    /// The editor saved, deleted, imported or reloaded something. Positions and rules an Undo remembers may be stale.
    func libraryChanged() {
        clearUndo()
        startReload()
    }

    func dismiss(_ suggestion: SpellingSuggestion) {
        dismissed.counts[suggestion.id] = max(suggestion.count, 1)
        do { try dismissed.write(to: dismissedURL); error = nil } catch { self.error = "Couldn't remember that dismissal: \(error.localizedDescription)" }
        publish()
    }

    private func finish(_ undo: Undo, dropping suggestion: SpellingSuggestion) {
        error = nil
        all.removeAll { $0.id == suggestion.id }
        publish()
        setUndo(undo)
        onRulesChanged()
        startReload()
    }

    private func setUndo(_ value: Undo) {
        undo = value
        undoTask?.cancel()
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func clearUndo() {
        undoTask?.cancel()
        undoTask = nil
        undo = nil
    }
}
