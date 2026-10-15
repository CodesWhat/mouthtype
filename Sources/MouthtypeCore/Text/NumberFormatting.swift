import Foundation

/// Inverse text normalisation: finds spoken numbers in `text` and says how to write them.
///
/// Implementations return spans over the Character offsets of `text`. They must not overlap. The pipeline
/// applies them and logs them as `number format` edits.
public protocol NumberFormatting: Sendable {
    func spans(in text: String) -> [TextSpan]
}

/// Vocabulary shared by the number formatter and the filler stage (repeated numbers are never stutters).
enum NumberWords {
    static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    static func isNumberWord(_ w: String) -> Bool {
        w == "zero" || w == "hundred" || units[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil
    }

    static let ordinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth",
    ]
}
