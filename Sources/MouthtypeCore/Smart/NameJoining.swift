import Foundation

enum NameJoining {
    struct Candidate: Sendable, Equatable {
        var heard: String
        var written: String
        var range: Range<Int>
    }

    static func candidates(in text: String, spellings: [String]) -> [Candidate] {
        var names: [String: String] = [:]
        for name in spellings where (3...64).contains(name.count) && name.allSatisfy(\.isLetter) {
            if names[name.lowercased()] == nil { names[name.lowercased()] = name }
        }
        guard !names.isEmpty, let regex = try? NSRegularExpression(pattern: #"\p{L}+"#) else { return [] }
        let words = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Range<String.Index>? in
            Range(match.range, in: text)
        }
        var results: [Candidate] = []
        var index = 0
        while index < words.count {
            var letters = String(text[words[index]]).lowercased()
            var best: Candidate?
            if index + 1 < words.count {
                for end in (index + 1)..<min(index + 4, words.count) {
                    let gap = text[words[end - 1].upperBound..<words[end].lowerBound]
                    guard !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "\t" }) else { break }
                    letters += text[words[end]].lowercased()
                    if let name = names[letters] {
                        let range = words[index].lowerBound..<words[end].upperBound
                        let start = text.distance(from: text.startIndex, to: range.lowerBound)
                        best = Candidate(heard: String(text[range]), written: name, range: start..<(start + text[range].count))
                    }
                }
            }
            if let best {
                results.append(best)
                while index < words.count, text.distance(from: text.startIndex, to: words[index].lowerBound) < best.range.upperBound { index += 1 }
            } else {
                index += 1
            }
        }
        return results
    }

    static func applying(_ candidates: [Candidate], to text: String) -> String {
        var chars = Array(text)
        for candidate in candidates.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            chars.replaceSubrange(candidate.range, with: candidate.written)
        }
        return String(chars)
    }

    static func isProjectReference(_ candidate: Candidate, in text: String) -> Bool {
        let chars = Array(text)
        let before = String(chars[..<candidate.range.lowerBound])
        let after = String(chars[candidate.range.upperBound...])
        let artifact = #"^[ \t]+(?:build|repository|repo|release|service|commit|branch|workflow|deployment|tests|version|codebase|logs|update)\b"#
        let operation = #"\b(?:deploy|restart|debug|configure|upgrade|reinstall|uninstall|clone|fork)(?:[ \t]+the)?[ \t]+$"#
        return after.range(of: artifact, options: [.regularExpression, .caseInsensitive]) != nil
            || before.range(of: operation, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func preservesOrdinary(_ candidates: [Candidate], in output: String) -> Bool {
        let required = Dictionary(grouping: candidates, by: { $0.heard.lowercased() })
        return required.allSatisfy { phrase, occurrences in
            let pattern =
                #"(?<![\p{L}\p{N}_])"#
                + phrase.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
            return regex.numberOfMatches(in: output, range: NSRange(output.startIndex..., in: output)) >= occurrences.count
        }
    }
}
