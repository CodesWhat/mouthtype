import FluidAudio
import Foundation

/// What the caller knows about a take's language when it hands audio to an engine: a chosen language, or Auto with the
/// candidates it may be. The engine turns it into its own hint. `.english` is the 0.5.0 behavior.
public enum DictationLanguageRequest: Sendable, Equatable {
    case explicit(DictationLanguage)
    case auto(candidates: [DictationLanguage])

    public static let english = DictationLanguageRequest.explicit(.english)

    /// The language when the request settles it: an explicit one, or Auto with a single candidate (an empty set is
    /// English). Nil when Auto still has to choose between several.
    public var resolved: DictationLanguage? {
        switch self {
        case let .explicit(language): language
        case let .auto(candidates): candidates.count > 1 ? nil : (candidates.first ?? .english)
        }
    }

    /// Every language the take can be in.
    public var possibleLanguages: [DictationLanguage] {
        switch self {
        case let .explicit(language): [language]
        case let .auto(candidates): candidates.isEmpty ? [.english] : candidates
        }
    }

    /// Saved-word boosting uses an English model, so it only runs when English is possible.
    public var allowsVocabularyBoost: Bool {
        possibleLanguages.contains(.english)
    }

    /// Languages Parakeet writes in a non-Latin script. Its language hint is a script filter, so an English hint
    /// would suppress them.
    static let nonLatinScript: Set<DictationLanguage> = [.russian, .ukrainian, .bulgarian, .greek]

    /// The hint for Parakeet v3. Latin-script text is identical with the English hint, no hint or the language's own
    /// (checked in the engine evaluation), so English and Latin-only requests keep `.english`, which is also what
    /// 0.5.0 sent. Any Cyrillic or Greek possibility gets no hint. Never `.french`: it adds an English-word blocklist.
    public var parakeetHint: Language? {
        possibleLanguages.contains(where: { Self.nonLatinScript.contains($0) }) ? nil : .english
    }

    /// The language code for Whisper, or nil to let it detect the language.
    public var whisperLanguage: String? {
        resolved?.code
    }
}
