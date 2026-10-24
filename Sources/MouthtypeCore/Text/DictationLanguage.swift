import Foundation

/// The languages the shipped speech engines cover. Raw value is the BCP 47 language code.
///
/// A nil language anywhere in the text pipeline means English, so callers that never set one behave as before.
public enum DictationLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case bulgarian = "bg"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hindi = "hi"
    case hungarian = "hu"
    case italian = "it"
    case japanese = "ja"
    case latvian = "lv"
    case lithuanian = "lt"
    case maltese = "mt"
    case polish = "pl"
    case portuguese = "pt"
    case romanian = "ro"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case swedish = "sv"
    case russian = "ru"
    case tamil = "ta"
    case ukrainian = "uk"

    public var code: String { rawValue }

    public var requiresWhisper: Bool {
        switch self {
        case .japanese, .hindi, .tamil: true
        default: false
        }
    }

    public var isEnglish: Bool { self == .english }

    /// English name, for the picker.
    public var englishName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    /// The language for a code or locale identifier such as "de", "de-AT" or "pt_BR". Nil when unsupported.
    public init?(code: String) {
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        self.init(rawValue: base)
    }

    /// Treats nil as English, the rule every stage follows.
    public static func isEnglish(_ language: DictationLanguage?) -> Bool {
        language?.isEnglish ?? true
    }
}
