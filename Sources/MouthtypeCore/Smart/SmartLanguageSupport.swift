import Foundation

/// Which languages the model pass runs in. Fast (S1-mini) is English only. Thorough (Gemma 4 E4B) runs in the languages
/// that passed the bench eval's ship gate; any other language is skipped with the reason "language" and the Basic
/// output is delivered.
public enum SmartLanguageSupport {
    /// The reason a model pass is skipped for its language, as the result's `rejection` holds it.
    public static let skipReason = "language"

    /// The languages Thorough cleans besides English: the tier-1 languages that passed the ship gate in
    /// `docs/evals/language-cleanup-2026-10.md` (every fixture accepted by the guard and kept in its language). Any other
    /// language skips the model pass until it has been measured. Empty would make Thorough English only.
    public static let thoroughLanguages: Set<DictationLanguage> = [
        .german, .spanish, .french, .italian, .portuguese, .dutch, .polish, .russian,
    ]

    /// Whether the model pass at `level` runs for a take in `language`. Nil means English.
    public static func supports(
        level: CleanupLevel, language: DictationLanguage?, nativeControls: Bool = false,
        thorough: Set<DictationLanguage> = SmartLanguageSupport.thoroughLanguages
    ) -> Bool {
        guard let language, !language.isEnglish else { return true }
        return level == .medium && !nativeControls && thorough.contains(language)
    }

    /// How much more of the time budget a word costs in `language` than an English word does. The budgets are
    /// calibrated on English at about 1.4 tokens a word; scripts and word forms that tokenize into more pieces need
    /// proportionally longer, or the take times out and silently falls back to Basic. Measured as the median
    /// milliseconds per word against English in the same eval run, rounded up to a quarter. Languages not listed were at
    /// or under 1.05 times English, or haven't been measured and don't reach the model yet.
    public static func budgetMultiplier(for language: DictationLanguage?) -> Double {
        switch language {
        case .polish?, .czech?, .ukrainian?, .danish?: 1.5
        case .russian?: 1.25
        case .greek?: 1.75
        default: 1.0
        }
    }
}
