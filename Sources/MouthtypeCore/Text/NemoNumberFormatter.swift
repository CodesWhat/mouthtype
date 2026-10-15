import FluidAudio
import Foundation

/// Number formatting through FluidAudio's NeMo inverse text normaliser (`TextNormalizer.normalizeSentence`,
/// which wraps the C symbol `nemo_normalize_sentence`).
///
/// Opt-in, not the pipeline default. It is broader than `SpokenNumberFormatter` but, measured on this machine
/// (see the report with this change), it costs about 2.7 ms for 64 words, which alone blows the 5 ms budget
/// for a paragraph, and it rewrites ordinary speech: "give me a second" becomes "give me a 2nd", "no one came"
/// becomes "no 1 came", "ten to one" becomes "12:50", "two million three hundred thousand" becomes "2000300
/// thousand". It also emits 24-hour padded times ("02:30 p.m.").
///
/// The result is diffed back to the input as one coarse span (widened to whole words), so the edit log shows
/// one `number format` edit covering the changed region rather than one per number.
public struct NemoNumberFormatter: NumberFormatting {
    public init() {}

    public func spans(in text: String) -> [TextSpan] {
        let normalizer = TextNormalizer.shared
        guard normalizer.isNativeAvailable, !text.isEmpty else { return [] }
        let result = normalizer.normalizeSentence(text)
        guard result != text else { return [] }

        let a = Array(text)
        let b = Array(result)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        var start = prefix
        var end = a.count - suffix
        // Widen to whole words so the log reads "twenty one" -> "21", not "ty one" -> "1".
        while start > 0, !a[start - 1].isWhitespace { start -= 1 }
        while end < a.count, !a[end].isWhitespace { end += 1 }
        let newEnd = b.count - (a.count - end)
        guard start <= end, start <= newEnd, newEnd <= b.count else { return [] }
        return [TextSpan(range: start..<end, replacement: String(b[start..<newEnd]))]
    }
}
