import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct TextPipelineTests {
    private let pipeline = TextPipeline(dateFormatter: { _ in "October 12, 2026" })

    private func run(
        _ text: String,
        dictionary: [DictionaryRule] = [],
        snippets: [Snippet] = [],
        context: InsertionContext? = nil,
        clipboard: String? = nil,
        options: TextPipelineOptions = .all
    ) -> TextPipelineResult {
        pipeline.run(
            TextPipelineInput(
                text: text, dictionary: dictionary, snippets: snippets, context: context,
                now: Date(timeIntervalSince1970: 1_791_763_200), clipboard: clipboard, options: options
            ))
    }

    // MARK: Acceptance

    @Test func fillersThenCapital() {
        #expect(run("um so I think we should uh ship it").text == "So I think we should ship it")
    }

    @Test func meetingWithTimeAndNewLine() {
        let out = run("let's meet at two thirty p m new line bring the the deck")
        #expect(out.text == "Let's meet at 2:30 PM\nBring the deck")
    }

    @Test func ordinaryPeriodSurvives() {
        let out = run("The trial period ended")
        #expect(out.text == "The trial period ended")
        #expect(out.edits.isEmpty)
    }

    @Test(arguments: ["Run ./dusting --mode testing.", "Open ../notes.txt", "./dusting --mode testing."])
    func relativePathsSurviveTheFullPipeline(text: String) {
        #expect(run(text).text == text)
    }

    @Test func trialPeriodLowercaseInputGetsOnlyACapital() {
        let out = run("the trial period ended")
        #expect(out.text == "The trial period ended")
        #expect(out.edits.map(\.stage) == ["blend"])
    }

    @Test func dictionaryRuleOnSpokenName() {
        let out = run("send it to Mouth Type", dictionary: [DictionaryRule(heard: "Mouth Type", written: "Mouthtype")])
        #expect(out.text == "Send it to Mouthtype")
        #expect(out.edits.contains { $0.stage == "dictionary" && $0.fromText == "Mouth Type" && $0.toText == "Mouthtype" })
    }

    // MARK: Order interactions

    @Test func snippetExpansionIsNotDictionaryReplaced() {
        let out = run(
            "my sig",
            dictionary: [DictionaryRule(heard: "scott", written: "SCOTT")],
            snippets: [Snippet(trigger: "my sig", expansion: "Best, scott")]
        )
        #expect(out.text == "Best, scott")
    }

    @Test func dictionaryOutputIsNotFilledOrCommanded() {
        // The dictionary runs after fillers and commands, so its output is never mistaken for either.
        let out = run("say that", dictionary: [DictionaryRule(heard: "say that", written: "um new line")])
        #expect(out.text == "um new line")
    }

    @Test func dictionaryWordAtSentenceStartIsNotLowercasedByBlend() {
        let rules = [DictionaryRule(heard: "mouth type", written: "Mouthtype")]
        let out = run("mouth type is fast", dictionary: rules, context: InsertionContext(before: "I think", after: nil))
        #expect(out.text == "Mouthtype is fast")
        let plain = run("The deck is fast", context: InsertionContext(before: "I think", after: nil))
        #expect(plain.text == "the deck is fast")
    }

    @Test func lowercaseDictionaryWordAtStartIsNotCapitalised() {
        let rules = [DictionaryRule(heard: "n p m", written: "npm")]
        #expect(run("n p m install", dictionary: rules).text == "npm install")
    }

    @Test func snippetWordAtSentenceStartIsKeptMidSentence() {
        let out = run(
            "greeting there",
            snippets: [Snippet(trigger: "greeting", expansion: "Dear Scott,")],
            context: InsertionContext(before: "and then", after: nil)
        )
        #expect(out.text == "Dear Scott, there")
    }

    @Test func fillerRemovalThenCapitalisation() {
        #expect(run("uh the deck").text == "The deck")
        #expect(run("hello. uh the deck").text == "Hello. The deck")
    }

    @Test func commandsRunBeforeNumbers() {
        #expect(run("twenty one apples period").text == "21 apples.")
    }

    @Test func spokenPeriodThenCapitalAfterFillerRemoval() {
        #expect(run("I am done period um Next steps").text == "I am done. Next steps")
    }

    @Test func midSentenceContextBlendsThenDropsStop() {
        let out = run(
            "Then we ship it.",
            context: InsertionContext(before: "and", after: "more text")
        )
        #expect(out.text == "then we ship it")
    }

    // MARK: Passthrough and degenerate input

    @Test func emptyAndWhitespaceInput() {
        for text in ["", " ", "\n\t  \n"] {
            let out = run(text)
            #expect(out.text == "")
            #expect(out.edits.isEmpty)
        }
    }

    @Test func everyStageDisabledPassesThroughUntouched() {
        let text = "  um  the the deck new line  period , "
        let out = run(text, options: .none)
        #expect(out.text == text)
        #expect(out.edits.isEmpty)
        #expect(out.stageMillis.isEmpty)
    }

    @Test func perStageSwitchesWork() {
        let text = "um the the deck"
        #expect(run(text, options: TextPipelineOptions(fillers: false)).text == "Um the the deck")
        #expect(run(text, options: TextPipelineOptions(blend: false)).text == "The deck")
        #expect(run("twenty one", options: TextPipelineOptions(numbers: false)).text == "Twenty one")
        #expect(run("new line", options: TextPipelineOptions(spokenCommands: false)).text == "New line")
        let rules = [DictionaryRule(heard: "a", written: "b")]
        #expect(run("a", dictionary: rules, options: TextPipelineOptions(dictionary: false)).text == "A")
        let snip = [Snippet(trigger: "a", expansion: "b")]
        #expect(run("a", snippets: snip, options: TextPipelineOptions(snippets: false)).text == "A")
    }

    @Test func textWithNoLettersSurvives() {
        #expect(run("12345").text == "12345")
        #expect(run("% & *").text == "% & *")
        #expect(run("... ").text == "...")
        #expect(run("😀😀😀").text == "😀😀😀")
        #expect(run("$%^&*").text == "$%^&*")
    }

    @Test func unicodeSurvives() {
        #expect(run("café au lait, très bien").text == "Café au lait, très bien")
        #expect(run("你好,世界。").text == "你好,世界。")
        #expect(run("hello 😀 world 🎉").text == "Hello 😀 world 🎉")
        #expect(run("um 東京 uh 大阪").text == "東京 大阪")
        #expect(run("naïve façade over there").text == "Naïve façade over there")
        #expect(run("e\u{301}cole").text == "E\u{301}cole")
    }

    // MARK: Idempotence

    static let idempotentInputs = [
        "um so I think we should uh ship it",
        "let's meet at two thirty p m and bring the the deck",
        "the trial period ended",
        "send it to Mouth Type please",
        "I have twenty one apples and fifty percent of the pears",
        "hello, world. how are you today? fine.",
        "wait... what is going on here",
        "it costs five dollars and fifty cents",
        "café au lait, très bien 😀",
        "I think I I I know that that is true",
    ]

    @Test(arguments: idempotentInputs)
    func runningOnItsOwnOutputChangesNothing(_ text: String) {
        let rules = [DictionaryRule(heard: "Mouth Type", written: "Mouthtype")]
        let first = run(text, dictionary: rules)
        let second = run(first.text, dictionary: rules)
        #expect(second.text == first.text)
        #expect(second.edits.isEmpty, "second pass edited \(second.edits)")
    }

    @Test(arguments: idempotentInputs)
    func idempotentWithContext(_ text: String) {
        let ctx = InsertionContext(before: "and then", after: "more")
        let first = run(text, context: ctx)
        let second = run(first.text, context: ctx)
        #expect(second.text == first.text)
    }

    // MARK: Edit log

    static let logInputs: [(text: String, rules: [DictionaryRule], snippets: [Snippet], context: InsertionContext?)] = [
        ("um so I think we should uh ship it", [], [], nil),
        ("let's meet at two thirty p m new line bring the the deck", [], [], nil),
        (
            "send it to Mouth Type comma Then go new paragraph thanks",
            [DictionaryRule(heard: "Mouth Type", written: "Mouthtype")], [], nil
        ),
        (
            "uh my sig is twenty one dollars period",
            [], [Snippet(trigger: "my sig", expansion: "Best regards, Scott")], nil
        ),
        ("Then we ship it period", [], [], InsertionContext(before: "and", after: "x")),
        ("Hmm, I I think hello comma, world", [DictionaryRule(heard: "world", written: "World")], [], nil),
    ]

    @Test func replayingTheLogReproducesEveryStage() {
        for item in Self.logInputs {
            let (result, trace) = pipeline.runTraced(
                TextPipelineInput(
                    text: item.text, dictionary: item.rules, snippets: item.snippets, context: item.context,
                    now: Date(timeIntervalSince1970: 1_791_763_200)
                ))
            var logged: [EditOp] = []
            for stage in trace {
                let replayed = TextTestSupport.replay(stage.edits, on: stage.input)
                if stage.stage == "whitespace" {
                    #expect(stage.edits.isEmpty)
                    continue
                }
                #expect(
                    replayed == TextTestSupport.stripWhitespace(stage.output),
                    "stage \(stage.stage) of \(item.text.debugDescription)"
                )
                logged += stage.edits
            }
            #expect(logged == result.edits)
            // And every stage's output is the next stage's input.
            #expect(trace.first?.input == item.text)
            for (a, b) in zip(trace, trace.dropFirst()) { #expect(a.output == b.input) }
            #expect(trace.last?.output == result.text)
        }
    }

    @Test func editFieldsAreConsistent() {
        for item in Self.logInputs {
            let out = run(item.text, dictionary: item.rules, snippets: item.snippets, context: item.context)
            for e in out.edits {
                let from = e.fromText ?? ""
                let to = e.toText ?? ""
                #expect(e.wordDelta == TextMetrics.wordCount(to) - TextMetrics.wordCount(from))
                #expect(e.position >= 0)
                switch e.kind {
                case .delete: #expect(e.toText == nil && e.fromText != nil)
                case .insert: #expect(e.fromText == nil && e.toText != nil)
                case .replace: #expect(e.fromText != nil && e.toText != nil && from != to)
                }
                #expect(["filler", "spoken command", "number format", "dictionary", "snippet", "blend"].contains(e.stage))
            }
        }
    }

    @Test func countsByStage() {
        let out = run(
            "um so uh send it to Mouth Type comma Then my sig twenty one apples",
            dictionary: [DictionaryRule(heard: "Mouth Type", written: "Mouthtype")],
            snippets: [Snippet(trigger: "my sig", expansion: "Scott")]
        )
        #expect(out.text == "So send it to Mouthtype, Then Scott 21 apples")
        let counts = Dictionary(grouping: out.edits, by: \.stage).mapValues(\.count)
        #expect(counts["filler"] == 3)  // um, so -> So, uh
        #expect(counts["spoken command"] == 1)  // comma
        #expect(counts["number format"] == 1)
        #expect(counts["dictionary"] == 1)
        #expect(counts["snippet"] == 1)
        #expect(counts["blend"] == nil)
    }

    @Test func positionsAreRelativeToTheStageInput() {
        let out = run("um hello. new line there")
        // filler: "um" at 0. Command stage sees "hello. new line there" ("Hello." after the cap edit).
        #expect(out.edits.first?.stage == "filler")
        #expect(out.edits.first?.position == 0)
        let command = out.edits.first { $0.stage == "spoken command" && $0.fromText == "new line" }
        #expect(command?.position == 7)
    }

    @Test func stageTimingsAreReported() {
        let out = run("hello world", dictionary: [DictionaryRule(heard: "a", written: "b")])
        #expect(Set(out.stageMillis.keys) == ["filler", "spoken command", "self-correction", "notation", "number format", "dictionary", "profanity", "blend", "whitespace"])
        #expect(out.stageMillis.values.allSatisfy { $0 >= 0 })
    }

    @Test func missingClipboardIsSurfaced() {
        let out = run("paste it", snippets: [Snippet(trigger: "paste it", expansion: "{clipboard}")], clipboard: nil)
        #expect(out.notes.count == 1)
    }

    // MARK: Injected number formatter

    @Test func aCustomNumberFormatterIsUsed() {
        struct Shout: NumberFormatting {
            func spans(in text: String) -> [TextSpan] {
                guard let r = text.range(of: "seven") else { return [] }
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                return [TextSpan(range: lo..<(lo + 5), replacement: "7")]
            }
        }
        let p = TextPipeline(numberFormatter: Shout())
        #expect(p.run(TextPipelineInput(text: "i have seven")).text == "I have 7")
    }

    // MARK: Performance

    static func paragraph(words target: Int) -> String {
        let sentence =
            "um so I think we should uh ship the the new build to twenty one customers period "
            + "the trial period is over and Mouth Type works fine comma then we send it to my sig new line "
            + "let's meet at two thirty p m and bring the deck. "
        var text = ""
        while TextMetrics.wordCount(text) < target { text += sentence }
        return text
    }

    private func benchmarkInput(_ text: String) -> TextPipelineInput {
        TextPipelineInput(
            text: text,
            dictionary: [
                DictionaryRule(heard: "Mouth Type", written: "Mouthtype"),
                DictionaryRule(heard: "post hog", written: "PostHog"),
                DictionaryRule(heard: "api", written: "API"),
            ],
            snippets: [Snippet(trigger: "my sig", expansion: "Best, Scott {date}")],
            context: InsertionContext(before: "and then", after: nil)
        )
    }

    @Test func threeHundredWordParagraphIsFast() {
        let input = benchmarkInput(Self.paragraph(words: 300))
        _ = pipeline.run(input)  // warm up
        let clock = ContinuousClock()
        let runs = 50
        let elapsed = clock.measure { for _ in 0..<runs { _ = pipeline.run(input) } }
        let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / Double(runs)
        print("TEXTPIPELINE-PERF 300 words: \(ms) ms average over \(runs) runs")
        #if DEBUG
        // Debug builds are several times slower than release; the 5 ms target applies to release.
        #expect(ms < 50, "300 words took \(ms) ms")
        #else
        #expect(ms < 5, "300 words took \(ms) ms")
        #endif
    }

    @Test func tenThousandWordsFinishes() {
        let input = benchmarkInput(Self.paragraph(words: 10_000))
        let clock = ContinuousClock()
        var out = TextPipelineResult(text: "")
        let elapsed = clock.measure { out = pipeline.run(input) }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("TEXTPIPELINE-PERF 10000 words: \(ms) ms")
        #expect(!out.text.isEmpty)
        #expect(!out.edits.isEmpty)
        #expect(ms < 3000, "10,000 words took \(ms) ms")
    }
}
