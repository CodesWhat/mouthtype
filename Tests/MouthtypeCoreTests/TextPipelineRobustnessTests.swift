import Foundation
import Testing
@testable import MouthtypeCore

/// Deterministic fuzzing: whatever the engine returns, the pipeline must not crash, must log edits that replay,
/// and must keep its output stable under the whitespace pass.
@Suite struct TextPipelineRobustnessTests {
    private struct LCG {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
    }

    private static let vocabulary: [String] = [
        "um", "uh", "the", "the", "I", "I'm", "new", "line", "paragraph", "period", "comma", "question", "mark",
        "twenty", "one", "two", "thirty", "hundred", "and", "point", "five", "percent", "dollars", "cents", "p", "m",
        "o'clock", "a", "ship", "deck", "Mouth", "Type", "my", "sig", "café", "東京", "😀", "👍🏽", "e\u{301}",
        ",", ".", "?", "!", ":", ";", "(", ")", "\"", "…", "-", "\n", "\n\n", "  ", "\t", "{date}", "{clipboard}",
        "12", "3.5", "$", "%", "ß", "İstanbul", "ﬁ", "\u{200B}", "\u{0}",
    ]

    private func randomText(_ rng: inout LCG) -> String {
        let count = rng.next() % 24
        var parts: [String] = []
        for _ in 0..<count {
            parts.append(Self.vocabulary[rng.next() % Self.vocabulary.count])
        }
        return parts.joined(separator: rng.next() % 5 == 0 ? "" : " ")
    }

    @Test func fuzzNeverCrashesAndTheLogReplays() {
        let pipeline = TextPipeline(dateFormatter: { _ in "D" })
        var rng = LCG(state: 42)
        let rules = [DictionaryRule(heard: "Mouth Type", written: "Mouthtype"), DictionaryRule(heard: "deck", written: "Deck")]
        let snippets = [Snippet(trigger: "my sig", expansion: "Best {date} {clipboard}")]
        for round in 0..<1500 {
            let text = randomText(&rng)
            let ctx: InsertionContext? = round % 3 == 0 ? nil : InsertionContext(before: round % 3 == 1 ? "and" : "Done. ", after: round % 7 == 0 ? "x" : nil)
            let (result, trace) = pipeline.runTraced(
                TextPipelineInput(
                    text: text, dictionary: rules, snippets: snippets, context: ctx, now: Date(timeIntervalSince1970: 0), clipboard: round % 2 == 0 ? "clip" : nil
                ))
            for stage in trace where stage.stage != "whitespace" {
                #expect(
                    TextTestSupport.replay(stage.edits, on: stage.input) == TextTestSupport.stripWhitespace(stage.output),
                    "round \(round) stage \(stage.stage) input \(stage.input.debugDescription)"
                )
            }
            #expect(WhitespaceNormalizer().apply(result.text) == result.text, "round \(round)")
            for e in result.edits { #expect(e.position >= 0) }
        }
    }

    @Test func eachStageIsTotalOnOddInput() {
        let odd = ["", " ", "\n", "\u{0}", "😀", "e\u{301}", "\r\n\r\n", "um", "period", "new line", "one", "-", "'", "''", "o'clock", "{", "}", "{date"]
        for text in odd {
            _ = FillerRemover().apply(text)
            _ = SpokenCommands().apply(text)
            _ = SpokenNumberFormatter().spans(in: text)
            _ = DictionaryReplacer(rules: [DictionaryRule(heard: "um", written: "X")]).apply(text)
            _ = SnippetExpander(snippets: [Snippet(trigger: "one", expansion: "{date}{")], now: Date(), clipboard: nil).apply(text)
            _ = BlendStage(context: InsertionContext(before: "a", after: "b")).apply(text)
            _ = WhitespaceNormalizer().apply(text)
        }
    }
}
