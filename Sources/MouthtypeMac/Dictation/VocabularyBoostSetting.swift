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

    /// The bias to send with a request: nil when the setting is off or nothing is saved.
    static func bias(enabled: Bool, rules: [DictionaryRule]) -> VocabularyBias? {
        guard enabled else { return nil }
        let bias = VocabularyBias.collect(from: rules)
        return bias.isEmpty ? nil : bias
    }
}
