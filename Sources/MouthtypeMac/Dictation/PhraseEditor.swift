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

    private func setDraft(_ phrase: Snippet?) {
        original = phrase
        trigger = phrase?.trigger ?? ""
        expansion = phrase?.expansion ?? ""
    }
}

/// What a row on the Transforms page does. A phrase that uses the clipboard placeholder is a clipboard phrase, every other phrase
/// is plain text, and Clean Selected Text is the built-in menu action.
enum TransformKind: String, CaseIterable {
    case text, clipboard, cleanSelection

    var title: String {
        switch self {
        case .text: "text"
        case .clipboard: "clipboard"
        case .cleanSelection: "clean selection"
        }
    }

    static func of(_ phrase: Snippet) -> TransformKind {
        phrase.expansion.localizedCaseInsensitiveContains("{clipboard}") ? .clipboard : .text
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
