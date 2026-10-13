import Foundation

/// Sets off a spoken correction with commas before the model sees it. S1-mini resolves "at two, actually three"
/// reliably and reads "at two actually three." as a list, so a cue that follows a value or a name gets the comma a
/// writer would have put there. Words are untouched; a cue after an ordinary word ("I actually enjoyed") is left
/// alone.
enum CorrectionCommas {
    /// The cues that signal a replacement. The comma after is added only where the cue is a phrase of its own.
    private static let cues: [(words: [String], commaAfter: Bool)] = [
        (["actually"], false), (["no", "wait"], true), (["no", "sorry"], true), (["sorry"], false),
        (["i", "mean"], false), (["or", "rather"], false), (["make", "that"], false), (["scratch", "that"], true),
    ]

    private static let valueWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    static func apply(_ text: String) -> String {
        let chars = Array(text)
        let lower = TextScan.lowered(chars)
        let words = TextScan.words(chars, lower)
        var inserts = Set<Int>()
        var k = 1
        while k < words.count {
            guard let cue = cues.first(where: { matches($0.words, at: k, words: words, chars: chars) }) else { k += 1; continue }
            let previous = words[k - 1]
            if TextScan.onlySpaces(chars, previous.end, words[k].start), isValueOrName(k - 1, words: words, chars: chars) {
                inserts.insert(previous.end)
                let end = words[k + cue.words.count - 1].end
                if cue.commaAfter, end < chars.count, TextScan.isSpace(chars[end]),
                   k + cue.words.count < words.count, TextScan.onlySpaces(chars, end, words[k + cue.words.count].start) {
                    inserts.insert(end)
                }
            }
            k += cue.words.count
        }
        guard !inserts.isEmpty else { return text }
        var out = ""
        for (index, char) in chars.enumerated() {
            if inserts.contains(index) { out.append(",") }
            out.append(char)
        }
        return out
    }

    private static func matches(_ cue: [String], at k: Int, words: [ScanWord], chars: [Character]) -> Bool {
        guard k + cue.count <= words.count else { return false }
        for (offset, word) in cue.enumerated() {
            guard words[k + offset].lower == word else { return false }
            if offset > 0, !TextScan.onlySpaces(chars, words[k + offset - 1].end, words[k + offset].start) { return false }
        }
        return true
    }

    private static func isValueOrName(_ index: Int, words: [ScanWord], chars: [Character]) -> Bool {
        let word = words[index]
        if NumberWords.isNumberWord(word.lower) || NumberWords.ordinals.contains(word.lower) || valueWords.contains(word.lower) {
            return true
        }
        if word.lower.contains(where: \.isNumber) { return true }
        // A capitalised word inside a sentence is a name or a place.
        guard chars[word.start].isUppercase, word.lower != "i", !word.lower.hasPrefix("i'") else { return false }
        var i = word.start - 1
        while i >= 0, TextScan.isSpace(chars[i]) { i -= 1 }
        guard i >= 0 else { return false }
        return !".!?\n:".contains(chars[i])
    }
}
