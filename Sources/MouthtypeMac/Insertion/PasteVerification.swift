import Foundation

/// What a field looked like at one read.
struct FieldReading: Equatable, Sendable {
    var value: String?
    var length: Int?
    var selection: NSRange?

    /// All three can be compared.
    var isComplete: Bool { value != nil && length != nil && selection != nil }
}

enum PasteVerdict: Equatable, Sendable {
    /// The field changed, or now holds the pasted text.
    case confirmed
    /// Nothing about the field changed and nothing else could have changed it.
    case notLanded
    /// Can't tell: the field isn't readable, focus moved, or the user did something.
    case unknown

    /// The store's `insert_outcome` vocabulary.
    var storeOutcome: String {
        switch self {
        case .confirmed: "confirmed"
        case .notLanded: "not landed"
        case .unknown: "unknown"
        }
    }
}

/// How a verification ended: for which delivery, and how long the target took to read the paste if it did.
struct PasteVerification: Equatable, Sendable {
    var id: Int
    var verdict: PasteVerdict
    var receiptMs: Int?
}

/// Reads the verdict off what the field looked like before the paste and at each re-read after it.
///
/// Built to stay quiet: a missed failure costs the user nothing they didn't have, a false "didn't land" on a paste
/// that worked makes them doubt a good tool. Only `notLanded` speaks, and it needs every read to agree.
///
/// `confirmed` arms Return after insert, so with a readable field it needs the pasted text itself to show up, not just
/// a change: a clipboard sync racing a slow target can make the target paste the user's previous clipboard, and that
/// changes the field too. Fields rewrite whitespace freely (a single-line input drops newlines, a web editor turns
/// spaces into no-break spaces, a code editor indents), so the comparison ignores whitespace altogether.
enum PasteVerifier {
    struct Baseline: Equatable, Sendable {
        var reading: FieldReading
        /// How many real key presses and clicks had happened right after the paste; nil when unknown.
        var input: UInt64?
        var unchangedProvesFailure = true
    }

    struct Observation: Equatable, Sendable {
        var reading: FieldReading?
        /// Focus is still on the element the paste went to.
        var focusSame: Bool
        var input: UInt64?
    }

    /// Whether this one read already proves the paste landed.
    static func confirms(_ observation: Observation, baseline: Baseline, pasted: String) -> Bool {
        guard observation.focusSame, let now = observation.reading else { return false }
        let before = baseline.reading
        let quiet = observation.input != nil && observation.input == baseline.input
        guard let beforeValue = before.value else {
            // No text to compare with: the text showing up, or any change with no input in between, is the paste.
            if let value = now.value, compact(value).contains(compact(pasted)) { return true }
            let changed = differs(before.length, now.length) || differs(before.selection, now.selection)
            return changed && quiet
        }
        guard let value = now.value else { return false }
        let key = compact(pasted)
        if !key.isEmpty, occurrences(of: key, in: compact(value)) > occurrences(of: key, in: compact(beforeValue)) { return true }
        // Pasting over a selection that already held the text gains nothing; the field reading exactly as the paste
        // would leave it is the evidence then.
        if let expected = replacing(before.selection, in: beforeValue, with: pasted) {
            if key.isEmpty ? expected == value : compact(expected) == compact(value) { return true }
        }
        // A field that rewrites characters (quotes, dashes) still took the text if what it gained is nearly the text.
        guard quiet, let gained = inserted(before: beforeValue, now: value, selection: before.selection) else { return false }
        return nearlyEqual(compact(gained), key)
    }

    /// The verdict once every read is in. `expected` is how many reads were planned.
    static func judge(baseline: Baseline?, pasted: String, observations: [Observation], expected: Int) -> PasteVerdict {
        guard let baseline else { return .unknown }
        if observations.contains(where: { confirms($0, baseline: baseline, pasted: pasted) }) { return .confirmed }
        guard baseline.unchangedProvesFailure, observations.count == expected,
            baseline.reading.isComplete, let input = baseline.input
        else { return .unknown }
        for observation in observations {
            guard observation.focusSame, let now = observation.reading, now.isComplete, observation.input == input,
                now == baseline.reading
            else { return .unknown }
        }
        return .notLanded
    }

    /// Format characters a web editor leaves around a caret, and the joiners inside emoji; neither says anything about
    /// what was pasted.
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// The text with every whitespace, newline and invisible format character removed.
    static func compact(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where !CharacterSet.whitespacesAndNewlines.contains(scalar) && !invisible.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// Non-overlapping occurrences of `needle`.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while let found = haystack.range(of: needle, options: .literal, range: from..<haystack.endIndex) {
            count += 1
            from = found.upperBound
        }
        return count
    }

    /// `text` with `selection` replaced by `pasted`, or nil when the selection isn't known or doesn't fit the text.
    private static func replacing(_ selection: NSRange?, in text: String, with pasted: String) -> String? {
        guard let selection, selection.location != NSNotFound, selection.length >= 0 else { return nil }
        let utf16 = text as NSString
        guard selection.location + selection.length <= utf16.length else { return nil }
        return utf16.replacingCharacters(in: selection, with: pasted)
    }

    /// What one edit put into the field, given how it read before and after. Nil when the reads don't fit a single
    /// insertion (or replacement of the selection) with the rest of the text left alone.
    private static func inserted(before: String, now: String, selection: NSRange?) -> String? {
        let old = before as NSString, new = now as NSString
        if let selection, selection.location != NSNotFound, selection.location + selection.length <= old.length {
            let gained = new.length - old.length + selection.length
            let tail = selection.location + selection.length
            if gained >= 0, selection.location + gained <= new.length,
                new.substring(to: selection.location) == old.substring(to: selection.location),
                new.substring(from: selection.location + gained) == old.substring(from: tail)
            {
                return new.substring(with: NSRange(location: selection.location, length: gained))
            }
        }
        let gained = new.length - old.length
        guard gained > 0 else { return nil }
        var prefix = 0
        while prefix < old.length, prefix + gained < new.length, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        guard new.substring(from: prefix + gained) == old.substring(from: prefix) else { return nil }
        return new.substring(with: NSRange(location: prefix, length: gained))
    }

    /// Same length and at most one character in ten differs, as a field that swaps quotes or dashes leaves it.
    private static func nearlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
        guard !a.isEmpty, a.count == b.count else { return false }
        let allowed = max(1, a.count / 10)
        var differing = 0
        for (x, y) in zip(a, b) where x != y {
            differing += 1
            if differing > allowed { return false }
        }
        return true
    }

    private static func differs<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}
