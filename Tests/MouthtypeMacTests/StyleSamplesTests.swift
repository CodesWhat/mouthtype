import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct StyleSamplesTests {
    private func added(_ segments: [StyleSampleSegment]) -> String { segments.filter(\.added).map(\.text).joined() }
    private func text(_ segments: [StyleSampleSegment]) -> String { segments.map(\.text).joined() }

    @Test func diffMarksOnlyWhatWasAdded() {
        let segments = StyleSamples.segments(spoken: "hey are we on", styled: "Hey, are we on?")
        #expect(text(segments) == "Hey, are we on?")
        #expect(added(segments) == "H,?")
    }

    @Test func diffNeverMarksWhitespace() {
        let segments = StyleSamples.segments(spoken: "a b", styled: "a, b")
        #expect(segments.filter { $0.text.contains(" ") }.allSatisfy { !$0.added || $0.text.contains(",") })
        #expect(added(segments) == ",")
    }

    @Test func tonesRunThroughTheRealStyleStage() {
        let line = StyleSamples.personal
        let formal = StyleSamples.render(line, tone: .formal)
        let casual = StyleSamples.render(line, tone: .casual)
        let veryCasual = StyleSamples.render(line, tone: .veryCasual)
        #expect(StyleSamples.plainText(formal) == line[0].engine)
        #expect(StyleSamples.plainText(casual) == StyleStage(options: StylePreset.casual.options).apply(line[0].engine).text)
        #expect(StyleSamples.plainText(casual) == "Hey, are we still on for dinner tonight? I can be there by seven")
        #expect(StyleSamples.plainText(veryCasual) == "hey, are we still on for dinner tonight? I can be there by seven")
        #expect(added(formal[0]).hasSuffix("."))
        #expect(!added(casual[0]).contains(".") && !added(veryCasual[0]).contains("H"))
        // "I" keeps its capital at every tone, so the highlight on it is the same in all three cards.
        #expect(added(veryCasual[0]).contains("I"))
    }

    @Test func excitedCardHighlightsTheExclamationMarkItAdded() {
        let line = StyleSamples.personal
        let formal = StyleSamples.render(line, tone: .formal)
        let excited = StyleSamples.render(line, tone: .excited)
        #expect(StyleSamples.plainText(excited) == "Hey, are we still on for dinner tonight? I can be there by seven!")
        #expect(added(excited[0]).hasSuffix("!") && !added(excited[0]).hasSuffix(".!"))
        #expect(added(formal[0]).hasSuffix("."))
        for id in StyleContextID.allCases {
            let lines = StyleSamples.lines(for: id)
            #expect(StyleSamples.plainText(StyleSamples.render(lines, tone: .excited)) != StyleSamples.plainText(StyleSamples.render(lines, tone: .formal)))
        }
    }

    @Test func everyContextHasASampleThatChangesWithTone() {
        for id in StyleContextID.allCases {
            let lines = StyleSamples.lines(for: id)
            #expect(!lines.isEmpty)
            let formal = StyleSamples.plainText(StyleSamples.render(lines, tone: .formal))
            let veryCasual = StyleSamples.plainText(StyleSamples.render(lines, tone: .veryCasual))
            #expect(formal != veryCasual)
        }
    }

    @Test func emailRunsAsOneTakePerLine() {
        let rendered = StyleSamples.render(StyleSamples.email, tone: .veryCasual)
        #expect(rendered.count == StyleSamples.email.count)
        #expect(StyleSamples.plainText(rendered).hasPrefix("hi Priya,\nthanks for the signed build."))
    }

    @Test func basicSampleComesFromThePipeline() {
        let basic = StyleSamples.basicOutput()
        #expect(!basic.isEmpty && basic != StyleSamples.messyEngine)
        #expect(!basic.lowercased().hasPrefix("um"))
    }
}
