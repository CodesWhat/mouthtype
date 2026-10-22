import Foundation
import MouthtypeCore

/// Sample dictations for the Style page. Each line is what was said (`spoken`, no capitals or punctuation beyond what the speaker
/// meant) and what the speech engine hands back (`engine`). The tone cards run `engine` through the real `StyleStage` and highlight
/// whatever differs from `spoken`, so nothing about the highlighting is written by hand.
struct StyleSampleLine: Equatable, Sendable {
    let spoken: String
    let engine: String
}

/// A run of characters in a sample, with whether the tone added it.
struct StyleSampleSegment: Equatable, Sendable {
    let text: String
    let added: Bool
}

enum StyleSamples {
    static let personal = [
        StyleSampleLine(
            spoken: "hey are we still on for dinner tonight i can be there by seven",
            engine: "Hey, are we still on for dinner tonight? I can be there by seven.")
    ]
    static let work = [
        StyleSampleLine(
            spoken: "quick update the deploy went out and the dashboards look fine",
            engine: "Quick update: the deploy went out, and the dashboards look fine.")
    ]
    /// An email is dictated a line at a time, so each line is its own take, as it is when you use the app.
    static let email = [
        StyleSampleLine(spoken: "hi Priya", engine: "Hi Priya,"),
        StyleSampleLine(
            spoken: "thanks for the signed build the release notes are in the PR",
            engine: "Thanks for the signed build. The release notes are in the PR."),
        StyleSampleLine(spoken: "can we do the review Thursday", engine: "Can we do the review Thursday?"),
        StyleSampleLine(spoken: "talk soon", engine: "Talk soon."),
    ]
    static let other = [
        StyleSampleLine(
            spoken: "sure i'll send the invoice tomorrow morning and copy Dan",
            engine: "Sure, I'll send the invoice tomorrow morning and copy Dan.")
    ]

    static func lines(for context: StyleContextID) -> [StyleSampleLine] {
        switch context {
        case .personal: personal
        case .work: work
        case .email: email
        case .other: other
        }
    }

    /// The sample as the tone leaves it, with the characters it added marked.
    static func render(_ lines: [StyleSampleLine], tone: StylePreset) -> [[StyleSampleSegment]] {
        let stage = StyleStage(options: tone.options)
        return lines.map { segments(spoken: $0.spoken, styled: stage.apply($0.engine).text) }
    }

    static func plainText(_ rendered: [[StyleSampleSegment]]) -> String {
        rendered.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    /// Longest common subsequence of `spoken` inside `styled`; every character of `styled` outside it is "added".
    /// Whitespace is never marked, and a changed letter ("h" to "H") counts as added.
    static func segments(spoken: String, styled: String) -> [StyleSampleSegment] {
        let a = Array(spoken), b = Array(styled)
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kept = [Bool](repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { kept[j] = true; i += 1; j += 1 } else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        var result: [StyleSampleSegment] = []
        for (index, character) in b.enumerated() {
            let added = !kept[index] && !character.isWhitespace
            if let last = result.last, last.added == added {
                result[result.count - 1] = StyleSampleSegment(text: last.text + String(character), added: added)
            } else {
                result.append(StyleSampleSegment(text: String(character), added: added))
            }
        }
        return result
    }

    // MARK: Cleanup tab

    /// The same messy take at every level. The engine output is a fixed example; Basic is the real pipeline's result for it.
    static let messyEngine = "Um, so can we move the sync to like ten, no, eleven tomorrow? I I want to finish the the pill sizing first."

    static func basicOutput() -> String {
        TextPipeline().run(TextPipelineInput(text: messyEngine, options: TextPipelineOptions())).text
    }

    /// Fast and Thorough rewrite with a local model, which a settings page can't run without loading it, so these two are written
    /// examples of what each level aims for and are labelled that way on the page.
    static let fastExample = "So can we move the sync to 11 tomorrow? I want to finish the pill sizing first."
    static let thoroughExample = "Can we move the sync to 11 tomorrow? I want to finish the pill sizing first."
}
