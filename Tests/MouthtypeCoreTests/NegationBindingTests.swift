import Testing

@testable import MouthtypeCore

@Suite struct NegationBindingTests {
    private func reason(_ input: String, _ output: String, level: CleanupLevel = .light) -> String? {
        SmartCleanupGuard.rejection(input: input, output: output, level: level)
    }

    @Test func aNegationMovedToAnotherWordIsRejected() {
        #expect(
            reason("I don't think the release is ready for customers.", "I think the release is not ready for customers.")
                == "negation changed")
        #expect(
            reason("We should not ship the beta to everyone today.", "We should ship the beta to nobody, not today.")
                != nil)
    }

    @Test func aNegationStayingOnItsWordPasses() {
        #expect(reason("um I do not think the release is ready for customers", "I do not think the release is ready for customers.") == nil)
        #expect(reason("we can't ship the beta to everyone today", "We can't ship the beta to everyone today.") == nil)
        #expect(reason("I do not like the new design at all", "I don't like the new design at all.") == nil)
    }

    @Test func correctionCuesAreNotNegations() {
        #expect(reason("Send it to Dana, no wait, send it to Priya.", "Send it to Priya.") == nil)
    }
}

@Suite struct NovelShareTests {
    @Test func anOutputThatIsHalfNewWordsIsRejected() {
        let reason = SmartCleanupGuard.rejection(
            input: "the quarterly budget review moves to Thursday afternoon",
            output: "the quarterly budget review moves to Thursday afternoon with catering, several extra guests and parking",
            level: .medium)
        #expect(reason?.contains("new") == true)
    }
}
