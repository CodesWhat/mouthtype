import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct TechnicalNotationTests {
    private func format(_ text: String) -> String {
        TextPipeline().run(TextPipelineInput(text: text, options: TextPipelineOptions(
            fillers: false, spokenCommands: false, selfCorrection: false, countedLists: false,
            numbers: false, dictionary: false, snippets: false, blend: false, whitespace: false))).text
    }

    @Test(arguments: [
        TextCase("the G P U needs a driver", "the GPU needs a driver"),
        TextCase("check the C-P-U usage", "check the CPU usage"),
        TextCase("the G.P.U. needs a driver", "the GPU needs a driver"),
        TextCase("the G.P.U must not overheat.", "the GPU must not overheat."),
        TextCase("use H T T P S", "use HTTPS"),
        TextCase("open a P R for this fix", "open a PR for this fix"),
        TextCase("enable T L S 1.3", "enable TLS 1.3"),
        TextCase("the I E E E standard", "the IEEE standard"),
        TextCase("label A B C D E F", "label ABCDEF"),
        TextCase("label U S B C", "label USBC"),
        TextCase("label USBC", "label USBC"),
        TextCase("the N V M E drive", "the NVME drive"),
        TextCase("a Q R T Z identifier", "a QRTZ identifier"),
        TextCase("the F B I's report", "the FBI's report"),
        TextCase("the F.B.I.'s report", "the FBI's report"),
        TextCase("use a U S B C cable", "use a USB-C cable"),
        TextCase("U-S-B-A", "USB-A"),
        TextCase("USB C", "USB-C"),
        TextCase("USBC", "USB-C"),
        TextCase("USB-C", "USB-C"),
        TextCase("😀 the H D M I cable", "😀 the HDMI cable"),
    ])
    func canonicalizesSpelledNotation(_ item: TextCase) {
        #expect(format(item.input) == item.expected)
        #expect(format(item.expected) == item.expected)
    }

    @Test(arguments: [
        "I A person", "I I think", "A D battery", "A U S B cable",
        "J R Smith", "J R R Tolkien", "G. P. U. are separate initials.",
        "G. P says no.", "G\nP\nU", "G, P, U", "type g p u",
        "open src/G-P-U.swift", "visit https://example.com/G-P-U",
        "mail G-P-U@example.com", "use `G P U` exactly", "use `G P U",
        "the variable G_P_U", "USB's C label", "the variable USBC", "the U, S, B, C and D labels",
    ])
    func preservesOrdinaryAndLiteralText(_ input: String) {
        #expect(format(input) == input)
    }

    @Test(arguments: ["the USBC build passed", "the U S B C build passed", "the USB C build passed"])
    func aNearbyProjectSpellingIsPreserved(_ input: String) {
        let result = TextPipeline().run(TextPipelineInput(text: input, context: InsertionContext(before: "Project: USBC\n")))
        #expect(result.text == "The USBC build passed")
    }

    @Test func unicodeEditPositionsReplay() {
        let input = "😀 café G P U"
        let result = TechnicalNotation().apply(input)
        #expect(result.text == "😀 café GPU")
        #expect(TextTestSupport.replay(result.edits, on: input) == TextTestSupport.stripWhitespace(result.text))
    }

    @Test func theNotationStageCanBeDisabled() {
        let result = TextPipeline().run(TextPipelineInput(text: "The G P U needs a driver", options: TextPipelineOptions(notation: false)))
        #expect(result.text == "The G P U needs a driver")
        #expect(result.stageMillis["notation"] == nil)
    }

    @Test func dictionaryAndSnippetSpellingsTakePriority() {
        let custom = TextPipeline().run(TextPipelineInput(text: "use G P U", dictionary: [DictionaryRule(heard: "G P U", written: "processor")]))
        #expect(custom.text == "Use processor")
        let literal = TextPipeline().run(TextPipelineInput(text: "my label", dictionary: [DictionaryRule(heard: "my label", written: "G P U")]))
        #expect(literal.text == "G P U")
        let snippet = TextPipeline().run(TextPipelineInput(text: "Q R Z", snippets: [Snippet(trigger: "Q R Z", expansion: "A B C")]))
        #expect(snippet.text == "A B C")
        #expect(!DictionaryRule(heard: "G P U", written: "gpu").isJoinedSpelling)
    }

    @Test func modelOutputGetsTheSameNotationPass() async {
        let cleaner = FakeCleaner(returning: "The G.P.U. needs a driver.")
        let result = await SmartCleanup(cleaner: cleaner).run(SmartCleanupRequest(text: "The GPU needs a driver.", level: .light))
        #expect(result.outcome == .ok)
        #expect(result.text == "The GPU needs a driver.")
        #expect(result.postEdits.contains { $0.fromText == "G.P.U." && $0.toText == "GPU" })
    }

    @Test(arguments: [
        TextCase("a four K monitor", "A 4K monitor"),
        TextCase("an eight K camera", "An 8K camera"),
        TextCase("the 4 K display", "The 4K display"),
        TextCase("a five K screen", "A 5K screen"),
        TextCase("four K dollars", "Four K dollars"),
        TextCase("four K races", "Four K races"),
    ])
    func resolutionNeedsDeviceContext(_ item: TextCase) {
        #expect(TextPipeline().run(TextPipelineInput(text: item.input)).text == item.expected)
    }
}
