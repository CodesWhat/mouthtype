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
            if let original { setDraft(items.first { $0.trigger == original.trigger }) }
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
