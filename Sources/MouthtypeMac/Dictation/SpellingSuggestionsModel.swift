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
              let saved = try? JSONDecoder().decode(DismissedSuggestions.self, from: data),
              saved.version == currentVersion else { return DismissedSuggestions() }
        return saved
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func hides(_ suggestion: SpellingSuggestion) -> Bool {
        guard let seen = counts[suggestion.id] else { return false }
        return suggestion.count < max(seen * 2, seen + 1)
    }
}

/// The Suggestions section of Saved spellings: runs the suggester over the newest takes off the main thread and applies
/// accepted, removed and dismissed suggestions. Active only while the window is open, like `HomeLogModel`; a run that
/// started before a deactivate or a newer run is dropped when it finishes.
@MainActor @Observable final class SpellingSuggestionsModel {
    static let takeLimit = 1_000

    /// What the last Add or Remove did, so Undo can put it back.
    struct Undo: Equatable {
        enum Action: Equatable { case added([DictionaryRule]), removed(DictionaryRule) }
        var message: String
        var action: Action
    }

    @ObservationIgnored var store: TranscriptStore? {
        didSet { if store !== oldValue, isActive { startReload() } }
    }
    @ObservationIgnored private let vocabulary: FileVocabulary
    @ObservationIgnored private let dismissedURL: URL
    @ObservationIgnored var onRulesChanged: @MainActor () -> Void = {}
    @ObservationIgnored var fetchRecent: @Sendable (TranscriptStore, Int) throws -> [DictationRecord] = { store, limit in
        try store.recentTakes(limit: limit)
    }
    @ObservationIgnored private var dismissed: DismissedSuggestions
    @ObservationIgnored private var all: [SpellingSuggestion] = []
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

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
        clearUndo()
    }

    func startReload() {
        guard isActive else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in await self?.reload() }
    }

    /// Reads the takes and current rules off the main thread, then keeps what hasn't been dismissed.
    func reload() async {
        guard let store else { all = []; publish(); return }
        generation += 1
        let mine = generation
        let fetch = fetchRecent
        let vocabulary = vocabulary
        let limit = Self.takeLimit
        let found = await Task.detached { () -> [SpellingSuggestion]? in
            guard let records = try? fetch(store, limit), let rules = try? vocabulary.allRules() else { return nil }
            return SpellingSuggester.suggest(takes: Self.takes(from: records), rules: rules)
        }.value
        guard mine == generation, !Task.isCancelled, let found else { return }
        all = found
        publish()
    }

    nonisolated static func takes(from records: [DictationRecord]) -> [SuggestionTake] {
        records.compactMap { record in
            guard record.isSecure != true, let raw = record.rawText, let final = record.finalText,
                  !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let boosted = record.boostTermsAppliedJson
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return SuggestionTake(id: record.id, rawText: raw, finalText: final, boostTermsApplied: boosted,
                app: record.appName, date: Date(timeIntervalSince1970: record.startedAt))
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
                let rule = DictionaryRule(heard: heard, written: suggestion.written)
                try vocabulary.save(original: nil, rule: rule)
                added.append(rule)
            }
        } catch {
            for rule in added { try? vocabulary.remove(rule) }
            self.error = error.localizedDescription
            return
        }
        finish(Undo(message: "Added \(suggestion.written).", action: .added(added)), dropping: suggestion)
    }

    func remove(_ suggestion: SpellingSuggestion) {
        guard suggestion.kind == .removeHazard, let heard = suggestion.heardForms.first else { return }
        do {
            let key = FileVocabulary.heardKey(heard)
            guard let rule = try vocabulary.allRules().first(where: { FileVocabulary.heardKey($0.heard) == key }) else {
                error = "That spelling is already gone."
                startReload()
                return
            }
            try vocabulary.remove(rule)
            finish(Undo(message: "Removed \(rule.heard).", action: .removed(rule)), dropping: suggestion)
        } catch { self.error = error.localizedDescription }
    }

    func undoLast() {
        guard let undo else { return }
        do {
            switch undo.action {
            case .added(let rules):
                let current = try vocabulary.allRules()
                for rule in rules where current.contains(rule) { try vocabulary.remove(rule) }
            case .removed(let rule):
                try vocabulary.save(original: nil, rule: rule)
            }
            clearUndo()
            error = nil
            onRulesChanged()
            startReload()
        } catch { self.error = error.localizedDescription }
    }

    func dismiss(_ suggestion: SpellingSuggestion) {
        dismissed.counts[suggestion.id] = max(suggestion.count, 1)
        do { try dismissed.write(to: dismissedURL); error = nil }
        catch { self.error = "Couldn't remember that dismissal: \(error.localizedDescription)" }
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
