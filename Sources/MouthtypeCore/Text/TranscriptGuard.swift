import Foundation

/// What the guard decided about one transcription.
public struct GuardedTranscript: Sendable, Equatable {
    public var text: String
    /// Nothing worth delivering: too little voiced audio, or no words left.
    public var isEmpty: Bool
    public var edits: [EditOp]

    public init(text: String, isEmpty: Bool, edits: [EditOp] = []) {
        self.text = text
        self.isEmpty = isEmpty
        self.edits = edits
    }
}

/// Catches engine output that is not speech, before the text pipeline sees it.
///
/// - Under `minVoicedMs` of voiced audio, or no letters or digits in the text: empty.
/// - A bracketed non-speech tag (`[BLANK_AUDIO]`, `[MUSIC]`, `(silence)`, `*applause*`) is removed when it is a
///   whole token at the start or end of the text. In the middle of a sentence it is left alone.
/// - The start cue is recorded at the very start of every capture. When the first word begins within
///   `cueWindowSeconds`, is one short token, has confidence under `cueConfidence`, and is followed by a gap of at
///   least `cueGapSeconds` before the next word, it is dropped. "Short token" means a known cue sound (`Tink`,
///   `Ding`, `Beep`, `Mm`, `Hm`) or any word under four letters that is not a real opener (`I`, `A`, `OK`, `No`,
///   `Yes`, `Hi`, `So`, `We`, `It`, ...). A cue sound that is the only word is dropped without a gap to measure.
///
/// Only the removals are logged, as `filler` deletions. With `clean` false only the emptiness check runs.
public struct TranscriptGuard: Sendable {
    public static let stageName = FillerRemover.stageName
    public static let minVoicedMs = 150.0
    public static let cueWindowSeconds = 0.25
    public static let cueConfidence: Float = 0.5
    public static let cueGapSeconds = 0.2

    public static let cueSounds: Set<String> = ["tink", "ding", "beep", "mm", "hm"]

    /// Real words that start dictations and must survive the short-token rule.
    public static let realOpeners: Set<String> = [
        "i", "a", "ok", "no", "yes", "hi", "so", "we", "it", "he", "she", "is", "am", "as", "at", "be", "by", "do",
        "go", "if", "in", "me", "my", "of", "on", "or", "to", "up", "us", "oh", "ah", "hey", "yo", "the", "and",
        "but", "can", "did", "for", "get", "had", "has", "her", "him", "his", "how", "its", "let", "not", "now",
        "our", "out", "say", "see", "too", "was", "who", "why", "you", "yep", "yup", "nah", "yeah", "are", "all",
        "any", "off", "one", "two", "six", "ten", "new", "old", "end", "add", "ask", "try", "run", "fix", "set",
        "put", "use", "buy", "pay", "yet", "ago", "may", "wow", "ooh", "aha", "ugh", "hmm", "uh", "um",
    ]

    public init() {}

    public func apply(_ transcription: Transcription, voicedMs: Double?, clean: Bool = true) -> GuardedTranscript {
        let original = transcription.text
        if let voicedMs, voicedMs < Self.minVoicedMs { return GuardedTranscript(text: original, isEmpty: true) }
        guard clean else { return GuardedTranscript(text: original, isEmpty: !Self.hasContent(original)) }

        var text = original
        var edits: [EditOp] = []

        let removed = Self.removeArtefacts(text)
        text = removed.text
        edits += removed.edits

        if let cue = cueWord(transcription.words) {
            let stripped = Self.dropLeadingToken(text, matching: cue.word)
            if stripped != text {
                edits.append(
                    EditOp(
                        stage: Self.stageName, kind: .delete, fromText: cue.word, toText: nil, wordDelta: -1, position: 0
                    ))
                text = stripped
            }
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return GuardedTranscript(text: text, isEmpty: !Self.hasContent(text), edits: edits)
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: Start cue

    private func cueWord(_ words: [WordTiming]) -> WordTiming? {
        guard let first = words.first, first.start < Self.cueWindowSeconds, first.confidence < Self.cueConfidence else {
            return nil
        }
        let letters = first.word.lowercased().filter { $0.isLetter }
        guard !letters.isEmpty, !first.word.contains(where: \.isWhitespace) else { return nil }
        let isCueSound = Self.cueSounds.contains(letters)
        if !isCueSound {
            guard letters.count < 4, !Self.realOpeners.contains(letters) else { return nil }
        }
        if words.count > 1 {
            return words[1].start - first.end >= Self.cueGapSeconds ? first : nil
        }
        return isCueSound ? first : nil
    }

    /// Removes the first whitespace-separated token when it is exactly `word`.
    static func dropLeadingToken(_ text: String, matching word: String) -> String {
        let trimmed = text.drop(while: { $0.isWhitespace })
        let end = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        guard trimmed[trimmed.startIndex..<end] == word[...] else { return text }
        return String(trimmed[end...])
    }

    // MARK: Bracketed artefacts

    static let artefactTags: Set<String> = [
        "blank_audio", "blank audio", "music", "silence", "silent", "applause", "laughter", "noise", "noises",
        "inaudible", "background noise", "no speech", "static", "sound", "sounds", "cough", "coughing", "sighs",
        "typing", "unintelligible", "crosstalk", "background music", "music playing",
    ]

    static func removeArtefacts(_ text: String) -> (text: String, edits: [EditOp]) {
        let chars = Array(text)
        var out: [Character] = []
        var edits: [EditOp] = []
        var i = 0
        while i < chars.count {
            let open = chars[i]
            let close: Character? = open == "[" ? "]" : open == "(" ? ")" : open == "*" ? "*" : nil
            let startsToken = i == 0 || chars[i - 1].isWhitespace
            if let close, startsToken, i + 1 < chars.count, let end = chars[(i + 1)...].firstIndex(of: close),
                chars[..<i].allSatisfy(\.isWhitespace) || chars[(end + 1)...].allSatisfy(\.isWhitespace),
                end + 1 == chars.count || chars[end + 1].isWhitespace,
                artefactTags.contains(String(chars[(i + 1)..<end]).lowercased().trimmingCharacters(in: .whitespaces))
            {
                edits.append(
                    EditOp(
                        stage: stageName, kind: .delete, fromText: String(chars[i...end]), toText: nil, wordDelta: 0,
                        position: i
                    ))
                i = end + 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return (String(out), edits)
    }
}
