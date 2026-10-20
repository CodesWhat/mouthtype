import Foundation
import MouthtypeCore

/// "Boost my saved words while recognising". Off unless the user turns it on.
enum VocabularyBoostSetting {
    static let key = "boostSavedWordsWhileRecognising"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    /// The bias to send with a request: nil when the setting is off or nothing is saved. Editor terms go after the
    /// saved spellings, so they only fill what is left of the 200, and a name already saved keeps its own entry.
    static func bias(enabled: Bool, rules: [DictionaryRule], editorTerms: [VocabularyBias.Term] = []) -> VocabularyBias? {
        guard enabled else { return nil }
        let saved = VocabularyBias.collect(from: rules)
        let known = Set(saved.terms.map { $0.lowercased() })
        let extra = editorTerms.filter { !known.contains($0.text.lowercased()) }
        let bias = extra.isEmpty ? saved : VocabularyBias(entries: saved.entries + extra)
        return bias.isEmpty ? nil : bias
    }

    /// The applied terms to store: those that came only from the editor are dropped. Nil when none are left.
    static func withoutEditorTerms(_ applied: [String]?, editorTerms: [VocabularyBias.Term], rules: [DictionaryRule]) -> [String]? {
        guard let applied, !editorTerms.isEmpty else { return applied }
        let saved = Set(VocabularyBias.collect(from: rules).terms.map { $0.lowercased() })
        let editorOnly = Set(editorTerms.map { $0.text.lowercased() }).subtracting(saved)
        let kept = applied.filter { !editorOnly.contains($0.lowercased()) }
        return kept.isEmpty ? nil : kept
    }
}
