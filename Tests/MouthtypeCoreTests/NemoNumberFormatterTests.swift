import Testing
@testable import MouthtypeCore

/// The NeMo wrapper is opt-in. These tests pin that it is callable from MouthtypeCore and that its coarse span
/// replays correctly; they do not endorse its output (see the type's doc comment).
@Suite struct NemoNumberFormatterTests {
    private func format(_ text: String) -> StageResult {
        SpanRewriter.apply(NemoNumberFormatter().spans(in: text), to: Array(text), stage: "number format")
    }

    @Test func isCallableAndConvertsCardinals() {
        #expect(format("I have twenty one apples").text == "I have 21 apples")
        #expect(format("five dollars and fifty cents").text == "$5.50")
    }

    @Test func spanIsWidenedToWholeWordsAndReplays() {
        let text = "buy twenty one apples"
        let out = format(text)
        #expect(out.edits.count == 1)
        #expect(out.edits[0].fromText == "twenty one")
        #expect(out.edits[0].toText == "21")
        #expect(TextTestSupport.replay(out.edits, on: text) == TextTestSupport.stripWhitespace(out.text))
    }

    @Test func textWithNothingToConvertGivesNoSpans() {
        #expect(NemoNumberFormatter().spans(in: "hello world").isEmpty)
        #expect(NemoNumberFormatter().spans(in: "").isEmpty)
    }

    @Test func canBeInjectedIntoThePipeline() {
        let pipeline = TextPipeline(numberFormatter: NemoNumberFormatter())
        #expect(pipeline.run(TextPipelineInput(text: "i have twenty one apples")).text == "I have 21 apples")
    }

    @Test func knownDifferencesFromTheDefault() {
        // Documented reasons the default is the Swift formatter, kept as evidence.
        #expect(format("no one came").text == "no 1 came")
        #expect(SpokenNumberFormatter().spans(in: "no one came").isEmpty)
    }
}
