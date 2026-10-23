import Foundation
import Testing

@testable import MouthtypeCore

@Suite struct LanguageDetectionTests {
    private struct Stub: LanguageDetector {
        var answer: [(language: DictationLanguage, confidence: Double)]

        func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)] {
            answer
        }
    }

    private let sentence = "das ist ein ganz normaler Satz"

    private func resolver(_ answer: [(language: DictationLanguage, confidence: Double)]) -> LanguageResolver {
        LanguageResolver(detector: Stub(answer: answer))
    }

    @Test func aConfidentCandidateWins() {
        #expect(resolver([(.german, 0.9)]).detect(sentence, candidates: [.english, .german]) == .german)
    }

    @Test func lowConfidenceFallsBackToTheFirstCandidate() {
        #expect(resolver([(.german, 0.3)]).detect(sentence, candidates: [.english, .german]) == .english)
        #expect(resolver([(.german, 0.3)]).detect(sentence, candidates: [.german, .english]) == .german)
    }

    @Test func confidenceAtTheThresholdIsAccepted() {
        #expect(resolver([(.german, LanguageResolver.defaultConfidence)]).detect(sentence, candidates: [.english, .german]) == .german)
    }

    @Test func shortTakesFallBackWithoutAskingTheDetector() {
        #expect(resolver([(.german, 0.99)]).detect("guten Tag", candidates: [.english, .german]) == .english)
    }

    @Test func aLanguageOutsideTheCandidatesIsIgnored() {
        #expect(resolver([(.french, 0.99)]).detect(sentence, candidates: [.english, .german]) == .english)
    }

    @Test func noHypothesesFallBack() {
        #expect(resolver([]).detect(sentence, candidates: [.english, .german]) == .english)
    }

    @Test func oneCandidateSkipsDetection() {
        #expect(resolver([(.german, 0.99)]).detect(sentence, candidates: [.english]) == .english)
        #expect(resolver([(.german, 0.99)]).detect(sentence, candidates: []) == .english)
    }

    @Test func noDetectorMeansTheFirstCandidate() {
        #expect(LanguageResolver(detector: nil).detect(sentence, candidates: [.german, .english]) == .german)
    }

    @Test func aSettledRequestNeverDetects() {
        let always = resolver([(.german, 0.99)])
        #expect(always.resolve(.explicit(.polish), text: sentence) == .polish)
        #expect(always.resolve(.auto(candidates: [.spanish]), text: sentence) == .spanish)
        #expect(always.resolve(.auto(candidates: [.english, .german]), text: sentence) == .german)
    }
}
