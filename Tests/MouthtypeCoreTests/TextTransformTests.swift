import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct TextTransformSanitizeTests {
    @Test func embeddedTagsAndMarkupArePreserved() {
        let svg = "Use <text>Hello</text> in SVG."
        #expect(TextTransform.sanitize(svg, input: svg) == svg)
        #expect(TextTransform.sanitize(svg) == svg)
        let two = "<text>a</text> and <text>b</text>"
        #expect(TextTransform.sanitize(two) == two)
        #expect(TextTransform.sanitize("<transcript>Hi</transcript> is a tag.") == "<transcript>Hi</transcript> is a tag.")
        #expect(TextTransform.sanitize("Run <b>bold</b> text.") == "Run <b>bold</b> text.")
    }

    @Test func anOuterWrapperIsUnwrappedOnlyWhenTheInputDidNotHaveOne() {
        #expect(TextTransform.sanitize("<text>\nHello.\n</text>\n", input: "hello") == "Hello.")
        #expect(TextTransform.sanitize("<transcript>Hello.</transcript>", input: "hello") == "Hello.")
        let wrapped = "<text>Hello</text>"
        #expect(TextTransform.sanitize(wrapped, input: wrapped) == wrapped)
        #expect(TextTransform.sanitize("<text>Hello</text> there", input: "<text>Hello") == "<text>Hello</text> there")
    }

    @Test func modelAddedPreamblesAreRemovedButTheInputsOwnAreKept() {
        #expect(TextTransform.sanitize("Here is the corrected text:\n\nHe and I go.", input: "me and him goes") == "He and I go.")
        #expect(TextTransform.sanitize("Sure! Here's the shorter version:\nHe goes.", input: "he goes now") == "He goes.")
        #expect(TextTransform.sanitize("Here is the corrected text: He goes.", input: "he goes") == "He goes.")
        let own = "Here is the list:\n- apples"
        #expect(TextTransform.sanitize(own, input: own) == own)
        #expect(TextTransform.sanitize("Here is the list", input: "x") == "Here is the list")
    }

    @Test func aPreambleDictatedAfterASelfCorrectionIsKept() {
        let said = "here is the transcript no wait here is the cleaned transcript we leave at nine"
        let out = "Here is the transcript, no wait, here is the cleaned transcript: We leave at nine."
        #expect(TextTransform.sanitize("Here is the cleaned transcript: We leave at nine.", input: said)
            == "Here is the cleaned transcript: We leave at nine.")
        #expect(TextTransform.sanitize(out, input: said) == out)
        #expect(TextTransform.sanitize("Here is the cleaned transcript: We leave at nine.", input: "we leave at nine")
            == "We leave at nine.")
        #expect(TextTransform.sanitize("Here is the cleaned text:\nWe leave at nine.", input: said)
            == "We leave at nine.")
    }

    @Test func onlyPreamblesThatNameTheOutputAreRemoved() {
        #expect(TextTransform.sanitize("Here's the rewritten text:\nShip Friday.", input: "ship friday") == "Ship Friday.")
        #expect(TextTransform.sanitize("Here is the more formal version:\nShip Friday.", input: "ship friday") == "Ship Friday.")
        #expect(TextTransform.sanitize("Here is a version of the selected text:\nShip Friday.", input: "ship friday") == "Ship Friday.")
        let plan = "Here is the plan for Alice:\nShip Friday."
        #expect(TextTransform.sanitize(plan, input: "Here's the plan for Alice:\nShip Friday.") == plan)
        #expect(TextTransform.sanitize(plan, input: "ship friday") == plan)
        let list = "Here's a list of the items:\n- a"
        #expect(TextTransform.sanitize(list, input: "items a") == list)
    }

    @Test func wrappingQuotesAndFencesAreRemovedWhenTheInputHadNone() {
        #expect(TextTransform.sanitize("\"He goes.\"", input: "he goes") == "He goes.")
        #expect(TextTransform.sanitize("\u{201C}He goes.\u{201D}", input: "he goes") == "He goes.")
        #expect(TextTransform.sanitize("\"He goes.\"", input: "\"he goes.\"") == "\"He goes.\"")
        #expect(TextTransform.sanitize("\"a\" and \"b\"", input: "a and b") == "\"a\" and \"b\"")
        #expect(TextTransform.sanitize("```\nHe goes.\n```", input: "he goes") == "He goes.")
        #expect(TextTransform.sanitize("```swift\nlet x = 1\n```", input: "let x=1") == "let x = 1")
        #expect(TextTransform.sanitize("```\ncode\n```", input: "```\ncode\n```") == "```\ncode\n```")
    }

    @Test func layersPeelTogether() {
        #expect(TextTransform.sanitize("Here is the edited text:\n\"He goes.\"", input: "he goes") == "He goes.")
    }
}

@Suite struct TransformOutputLimitTests {
    @Test func allowanceFollowsEncodedLengthForTextWithoutSpaces() {
        let japanese = String(repeating: "あ", count: 600)
        #expect(CleanupLimits.maxOutputTokens(for: japanese) < 60)
        #expect(CleanupLimits.maxOutputTokens(for: japanese, inputTokens: 600) >= 1200)
        #expect(CleanupLimits.maxOutputTokens(for: "two words", inputTokens: 2) >= CleanupLimits.maxOutputTokens(for: "two words"))
        #expect(CleanupLimits.maxOutputTokens(for: "x", inputTokens: 1_000_000) == CleanupLimits.outputTokenCeiling)
    }

    @Test func truncatedGenerationThrowsInsteadOfReturningAFragment() throws {
        #expect(throws: CleanerError.outputTruncated) {
            try MLXCleaner.finalize("Hello th", input: "hello there", transform: .fixGrammar, truncated: true)
        }
        #expect(throws: CleanerError.outputTruncated) {
            try MLXCleaner.finalize("Hello th", input: "hello there", transform: nil, truncated: true)
        }
        #expect(try MLXCleaner.finalize(" Hello there. ", input: "hello there", transform: .fixGrammar, truncated: false) == "Hello there.")
        #expect(try MLXCleaner.finalize(" Hello there. ", input: "hello there", transform: nil, truncated: false) == "Hello there.")
    }

    @Test func wildlyLongOutputIsAFailedGeneration() {
        let input = "short text"
        let limit = input.count * 4 + 200
        #expect(!CleanupLimits.isImplausiblyLong(output: String(repeating: "a", count: limit), input: input))
        #expect(CleanupLimits.isImplausiblyLong(output: String(repeating: "a", count: limit + 1), input: input))
        #expect(throws: CleanerError.outputTooLong) {
            try MLXCleaner.finalize(String(repeating: "a", count: limit + 1), input: input, transform: .moreFormal, truncated: false)
        }
    }

    @Test func dictationCleanupFallsBackToTheUncleanedTextWhenGenerationTruncates() async {
        let cleaner = FakeCleaner { _, _ in throw CleanerError.outputTruncated }
        let smart = SmartCleanup(cleaner: cleaner, budget: { _ in .seconds(2) })
        let request = SmartCleanupRequest(text: "this is the original dictated text", level: .light)
        let result = await smart.run(request)
        #expect(result.outcome == .failed)
        #expect(result.text == request.text && result.modelText == nil)
    }
}
