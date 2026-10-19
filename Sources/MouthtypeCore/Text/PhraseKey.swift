import Foundation

/// The one way a phrase is compared: whitespace runs collapse to a single space, ends trimmed.
public enum PhraseKey {
    public static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func normalized(_ text: String) -> String {
        collapsed(text).lowercased()
    }
}
