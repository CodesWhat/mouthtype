import Foundation

/// Removes unambiguous fillers and immediate stutter repeats, and tidies the punctuation they leave behind.
///
/// Removed: standalone `um umm uh uhh uhm er erm hm hmm hmmm mm mmm` (any case, but an all-caps `ER` or `UM` is
/// left alone as an abbreviation), with an adjacent comma or sentence period; and a word repeated immediately
/// ("the the", "I I I") except the allow-list in `doubledAllowList`. Never touched: "like", "you know",
/// "actually", "sort of", "kind of", "I mean".
///
/// English only. The filler set contains real words in other languages (German "um" and "er").
public struct FillerRemover: Sendable {
    public static let stageName = "filler"

    public static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "hm", "hmm", "hmmm", "mm", "mmm",
    ]

    /// Words that legitimately appear twice in a row. "is is" is allowed only after "what it".
    public static let doubledAllowList: Set<String> = [
        "had", "that", "bye", "no", "very", "so", "ha", "knock", "blah",
    ]

    public init() {}

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        var scan = Scan(chars: chars)
        scan.run()
        return SpanRewriter.apply(scan.spans, to: chars, stage: Self.stageName)
    }

    private struct Scan {
        let chars: [Character]
        let n: Int
        let words: [ScanWord]
        var removed: [Bool]
        var spans: [TextSpan] = []
        var kept: [Int] = []
        var lastCutEnd = 0

        init(chars: [Character]) {
            self.chars = chars
            self.n = chars.count
            self.words = TextScan.words(chars, TextScan.lowered(chars))
            self.removed = [Bool](repeating: false, count: chars.count)
        }

        mutating func run() {
            for k in words.indices {
                if isFiller(k) {
                    handleFiller(k)
                } else if let p = kept.last, isStutter(k, previous: p) {
                    deleteStutter(k, previous: p)
                } else {
                    kept.append(k)
                }
            }
        }

        // MARK: Fillers

        func isFiller(_ k: Int) -> Bool {
            let w = words[k]
            guard FillerRemover.fillerWords.contains(w.lower) else { return false }
            let original = String(chars[w.start..<w.end])
            if original.count >= 2, original == original.uppercased(), original != original.lowercased() {
                return false
            }
            let leftOK = w.start == 0 || chars[w.start - 1].isWhitespace || "(\"\u{201C},\u{2026}".contains(chars[w.start - 1])
            let rightOK = w.end == n || chars[w.end].isWhitespace || ",.\u{2026})\"\u{201D}".contains(chars[w.end])
            return leftOK && rightOK
        }

        func sentenceStart(before pos: Int) -> Bool {
            var i = pos - 1
            while i >= 0, chars[i].isWhitespace || removed[i] {
                if chars[i].isNewline { return true }
                i -= 1
            }
            if i < 0 { return true }
            return ".!?\u{2026}".contains(chars[i])
        }

        mutating func add(core: Range<Int>, cut: Range<Int>, replacement: String) {
            let cutStart = max(cut.lowerBound, lastCutEnd)
            spans.append(TextSpan(range: core, cut: cutStart..<cut.upperBound, replacement: replacement))
            lastCutEnd = max(lastCutEnd, cut.upperBound)
            if replacement.isEmpty {
                for i in core { removed[i] = true }
            }
        }

        mutating func handleFiller(_ k: Int) {
            let w = words[k]
            let s = w.start, e = w.end
            var post: Character?
            if e < n, ",.\u{2026}".contains(chars[e]) { post = chars[e] }
            var j = s - 1
            while j >= 0, TextScan.isSpace(chars[j]) || removed[j] { j -= 1 }
            let hasPre = j >= 0 && chars[j] == ","
            let preIdx = j
            let atStart = !hasPre && sentenceStart(before: s)

            if atStart {
                let coreEnd = post != nil ? e + 1 : e
                var cutEnd = coreEnd
                while cutEnd < n, TextScan.isSpace(chars[cutEnd]) { cutEnd += 1 }
                add(core: s..<coreEnd, cut: s..<cutEnd, replacement: "")
                let next = k + 1
                if next < words.count, words[next].start == cutEnd, !isFiller(next),
                   let up = TextScan.capitalized(chars, words[next]) {
                    spans.append(TextSpan(range: words[next].start..<words[next].end, replacement: up))
                    lastCutEnd = max(lastCutEnd, words[next].end)
                }
            } else if hasPre {
                guard preIdx >= lastCutEnd else { return }
                let coreEnd = post != nil ? e + 1 : e
                var replacement = ""
                if let post { replacement = String(post) }
                add(core: preIdx..<coreEnd, cut: preIdx..<coreEnd, replacement: replacement)
            } else {
                switch post {
                case ",":
                    var after = e + 1
                    while after < n, TextScan.isSpace(chars[after]) { after += 1 }
                    add(core: s..<(e + 1), cut: s..<after, replacement: "")
                case .some:
                    var b = s
                    while b > lastCutEnd, TextScan.isSpace(chars[b - 1]) { b -= 1 }
                    add(core: s..<e, cut: b..<e, replacement: "")
                case .none:
                    var after = e
                    while after < n, TextScan.isSpace(chars[after]) { after += 1 }
                    if after < n, !chars[after].isNewline {
                        add(core: s..<e, cut: s..<after, replacement: "")
                    } else {
                        var b = s
                        while b > lastCutEnd, TextScan.isSpace(chars[b - 1]) { b -= 1 }
                        add(core: s..<e, cut: b..<e, replacement: "")
                    }
                }
            }
        }

        // MARK: Stutters

        func isStutter(_ k: Int, previous p: Int) -> Bool {
            let wk = words[k], wp = words[p]
            guard wk.lower == wp.lower else { return false }
            let t = wk.lower
            guard t.contains(where: { $0.isLetter }), !t.contains(where: { $0.isNumber }) else { return false }
            guard !FillerRemover.doubledAllowList.contains(t), !NumberWords.isNumberWord(t) else { return false }
            if t == "is", kept.count >= 3, words[kept[kept.count - 3]].lower == "what",
               words[kept[kept.count - 2]].lower == "it" {
                return false
            }
            var i = wp.end
            while i < wk.start {
                if !(TextScan.isSpace(chars[i]) || removed[i]) { return false }
                i += 1
            }
            return true
        }

        mutating func deleteStutter(_ k: Int, previous p: Int) {
            let wk = words[k]
            var b = wk.start
            let floor = max(lastCutEnd, words[p].end)
            while b > floor, TextScan.isSpace(chars[b - 1]) { b -= 1 }
            add(core: wk.start..<wk.end, cut: b..<wk.end, replacement: "")
        }
    }
}
