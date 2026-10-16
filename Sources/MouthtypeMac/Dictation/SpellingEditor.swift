import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class SpellingEditor {
    private let store: FileVocabulary
    private(set) var items: [DictionaryRule] = []
    private(set) var original: DictionaryRule?
    var heard = ""
    var written = ""
    private(set) var error: String?
    private(set) var loadFailed = false

    var isDirty: Bool { heard != (original?.heard ?? "") || written != (original?.written ?? "") }
    var validationMessage: String? { isDirty ? FileVocabulary.validationMessage(heard: heard, written: written) : nil }
    var canSave: Bool { !loadFailed && isDirty && validationMessage == nil }

    init(store: FileVocabulary) {
        self.store = store
        reload()
    }

    func reload() {
        guard !isDirty else { return }
        do {
            items = try store.allRules()
            loadFailed = false
            error = nil
            if let original { setDraft(items.first { FileVocabulary.heardKey($0.heard) == FileVocabulary.heardKey(original.heard) }) }
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
    }

    func select(_ rule: DictionaryRule) {
        guard !isDirty else { return }
        setDraft(rule)
        if !loadFailed { error = nil }
    }

    func newSpelling() {
        guard !isDirty, !loadFailed else { return }
        setDraft(nil)
        error = nil
    }

    func cancel() {
        setDraft(original)
        if !loadFailed { error = nil }
    }

    func save() {
        guard canSave else { return }
        do {
            let rule = DictionaryRule(heard: heard.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                written: written.trimmingCharacters(in: .whitespacesAndNewlines), starred: original?.starred ?? false)
            try store.save(original: original, rule: rule)
            setDraft(rule)
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

    private func setDraft(_ rule: DictionaryRule?) {
        original = rule
        heard = rule?.heard ?? ""
        written = rule?.written ?? ""
    }
}
