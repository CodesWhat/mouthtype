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

    /// The setting's value as the picker stores it: "auto" or a language code.
    var pickerValue: String {
        switch self {
        case .auto: Self.autoValue
        case let .explicit(language): language.code
        }
    }

    /// The setting for a picker value. Nil for anything that isn't Auto-detect or a supported language.
    init?(pickerValue: String) {
        if pickerValue == Self.autoValue {
            self = .auto
        } else if let language = DictationLanguage(rawValue: pickerValue) {
            self = .explicit(language)
        } else {
            return nil
        }
    }

    /// True for an explicit language other than English, where English-only cleanup stages and Fast don't run.
    var isExplicitNonEnglish: Bool {
        if case let .explicit(language) = self { return !language.isEnglish }
        return false
    }

    /// Languages Parakeet v3 transcribes noticeably worse than the rest (FLEURS word error of 25 percent or more).
    static let betaLanguages: Set<DictationLanguage> = [.lithuanian, .maltese, .latvian, .slovenian, .greek]

    /// Auto-detect, English, then the other 24 languages by English name, Beta marked on the weaker ones.
    static var pickerChoices: [DesignChoice<String>] {
        let others = DictationLanguage.allCases.filter { !$0.isEnglish }.sorted { $0.englishName < $1.englishName }
        return [DesignChoice("Auto-detect", autoValue), DesignChoice(DictationLanguage.english.englishName, DictationLanguage.english.code)]
            + others.map { DesignChoice(betaLanguages.contains($0) ? "\($0.englishName) (Beta)" : $0.englishName, $0.code) }
    }

    static let fastEnglishOnlyNote = "Fast cleanup is English only. Using Basic for this language."

    static let autoDetail = "Detected from your speech. Some cleanup steps are English only."
    static let detail = "Some cleanup steps are English only."
    /// The per-language breakdown behind the info button on the Language row.
    static let infoText =
        "Auto-detect picks the language from what you said, among English and your Mac\u{2019}s preferred languages.\n\n"
        + "English runs every cleanup rule. Other languages get punctuation, capitalization, your dictionary and snippets, and Thorough cleanup. "
        + "Fast, spoken commands, number formatting and filler removal are English only for now."

    /// What the engine and pipeline are told for a take.
    func request(preferredLanguages: [String] = Locale.preferredLanguages) -> DictationLanguageRequest {
        switch self {
        case .auto: .auto(candidates: Self.candidates(preferredLanguages: preferredLanguages))
        case let .explicit(language): .explicit(language)
        }
    }
}
