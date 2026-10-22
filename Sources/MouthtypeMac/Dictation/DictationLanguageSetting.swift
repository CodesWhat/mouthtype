import Foundation
import MouthtypeCore

/// "Dictation language": Auto-detect (the default) or one of the languages the engine covers.
enum DictationLanguageSetting: Equatable, Sendable {
    case auto
    case explicit(DictationLanguage)

    static let key = "dictationLanguage"
    private static let autoValue = "auto"

    static func load(_ defaults: UserDefaults = .standard) -> DictationLanguageSetting {
        guard let value = defaults.string(forKey: key), value != autoValue,
            let language = DictationLanguage(rawValue: value)
        else { return .auto }
        return .explicit(language)
    }

    static func set(_ setting: DictationLanguageSetting, in defaults: UserDefaults = .standard) {
        switch setting {
        case .auto: defaults.set(autoValue, forKey: key)
        case let .explicit(language): defaults.set(language.code, forKey: key)
        }
    }

    /// The Mac's preferred languages the engine supports, in order and without repeats. English is added last when the
    /// Mac doesn't list it, so a Mac that doesn't prefer English still recognizes it. The first entry is the primary
    /// language, the fallback for a take that can't be told apart. English-only Macs get `[.english]`.
    static func candidates(preferredLanguages: [String] = Locale.preferredLanguages) -> [DictationLanguage] {
        var seen = Set<DictationLanguage>()
        var result = preferredLanguages.compactMap(DictationLanguage.init(code:)).filter { seen.insert($0).inserted }
        if !seen.contains(.english) { result.append(.english) }
        return result
    }

    /// What the engine and pipeline are told for a take.
    func request(preferredLanguages: [String] = Locale.preferredLanguages) -> DictationLanguageRequest {
        switch self {
        case .auto: .auto(candidates: Self.candidates(preferredLanguages: preferredLanguages))
        case let .explicit(language): .explicit(language)
        }
    }
}
