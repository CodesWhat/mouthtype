import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class PhraseEditor {
    private let store: FilePhrases
    private(set) var items: [Snippet] = []
    private(set) var original: Snippet?
    var trigger = ""
    var expansion = ""
    private(set) var error: String?
    private(set) var loadFailed = false

    var isDirty: Bool { trigger != (original?.trigger ?? "") || expansion != (original?.expansion ?? "") }
    var canSave: Bool {
        !loadFailed && isDirty && !FilePhrases.triggerKey(trigger).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(store: FilePhrases) {
        self.store = store
        reload()
    }

    func reload() {
        guard !isDirty else { return }
        do {
            items = try store.all()
            loadFailed = false
            error = nil
            if let original { setDraft(items.first { FilePhrases.triggerKey($0.trigger) == FilePhrases.triggerKey(original.trigger) }) }
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
    }

    func select(_ phrase: Snippet) {
        guard !isDirty else { return }
        setDraft(phrase)
        error = nil
    }

    func newPhrase() {
        guard !isDirty else { return }
        setDraft(nil)
        error = nil
    }

    func cancel() {
        setDraft(original)
        error = nil
    }

    func save() {
        guard canSave else { return }
        do {
            let phrase = Snippet(trigger: trigger.split(whereSeparator: \.isWhitespace).joined(separator: " "), expansion: expansion)
            try store.save(original: original, phrase: phrase)
            setDraft(phrase)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func delete() {
        guard !isDirty, !loadFailed, let original else { return }
        do {
            try store.remove(original)
            setDraft(nil)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func draftSnapshot() -> DraftRecovery.Draft? {
        isDirty ? DraftRecovery.Draft(kind: .phrase, trigger: trigger, expansion: expansion) : nil
    }

    func restore(_ draft: DraftRecovery.Draft) {
        setDraft(nil)
        trigger = draft.trigger
        expansion = draft.expansion
    }

    private func setDraft(_ phrase: Snippet?) {
        original = phrase
        trigger = phrase?.trigger ?? ""
        expansion = phrase?.expansion ?? ""
    }
}

/// The kind tag on a Transforms page row, worked out from the saved text. A clipboard placeholder wins, then a date placeholder,
/// then a multi-line body, and everything else is plain text. The data format has no kind field.
enum TransformKind: Equatable {
    case text, lines(Int), clipboard, date

    var title: String {
        switch self {
        case .text: "TEXT"
        case let .lines(count): "\(count) LINES"
        case .clipboard: "CLIPBOARD"
        case .date: "DATE"
        }
    }

    static func of(_ phrase: Snippet) -> TransformKind {
        let text = phrase.expansion
        if text.localizedCaseInsensitiveContains("{clipboard}") { return .clipboard }
        if text.localizedCaseInsensitiveContains("{date}") { return .date }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return lines > 1 ? .lines(lines) : .text
    }
}

extension PhraseEditor {
    /// The saved phrases that match a search, by trigger, text or kind. An empty search matches everything.
    func matching(_ query: String) -> [Snippet] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.filter { phrase in
            terms.allSatisfy { term in
                phrase.trigger.localizedCaseInsensitiveContains(term) || phrase.expansion.localizedCaseInsensitiveContains(term)
                    || TransformKind.of(phrase).title.localizedCaseInsensitiveContains(term)
            }
        }
    }
}
