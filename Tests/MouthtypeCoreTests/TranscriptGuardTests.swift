import Testing
@testable import MouthtypeCore

@Suite struct TranscriptGuardTests {
    private func transcription(_ text: String, _ words: [(String, Double, Double, Float)] = []) -> Transcription {
        Transcription(
            text: text,
            words: words.map { WordTiming(word: $0.0, start: $0.1, end: $0.2, confidence: $0.3) },
            processingSeconds: 0.1, engineID: "test"
        )
    }

    private func guarded(_ text: String, _ words: [(String, Double, Double, Float)] = [], voiced: Double? = 1_000) -> GuardedTranscript {
        TranscriptGuard().apply(transcription(text, words), voicedMs: voiced)
    }

    @Test func tooLittleVoicedAudioIsEmpty() {
        #expect(guarded("hello there", voiced: 149).isEmpty)
        #expect(!guarded("hello there", voiced: 150).isEmpty)
        #expect(!guarded("hello there", voiced: nil).isEmpty)
    }

    @Test func textWithoutWordsIsEmpty() {
        #expect(guarded("").isEmpty)
        #expect(guarded("  ... ").isEmpty)
        #expect(guarded("hello").isEmpty == false)
    }

    @Test(arguments: ["[BLANK_AUDIO]", "[MUSIC]", "(silence)", "*applause*", "[Music]", " [BLANK_AUDIO] "])
    func bracketedArtefactsAloneAreEmpty(_ text: String) {
        let out = guarded(text)
        #expect(out.isEmpty)
        #expect(out.edits.count == 1)
        #expect(out.edits[0].stage == "filler")
        #expect(out.edits[0].kind == .delete)
    }

    @Test func standaloneArtefactsAreRemovedFromSpeech() {
        let out = guarded("[MUSIC] hello there [BLANK_AUDIO]")
        #expect(out.text == "hello there")
        #expect(out.edits.count == 2)
    }

    @Test func realBracketsSurvive() {
        #expect(guarded("see (silence) of the lambs").text == "see (silence) of the lambs")
        #expect(guarded("the array[music] is empty").text == "the array[music] is empty")
        #expect(guarded("(see below) for details").text == "(see below) for details")
        #expect(guarded("[1] is first").text == "[1] is first")
        #expect(guarded("[MUSIC]x").text == "[MUSIC]x")
    }

    // MARK: Start cue

    @Test func cueSoundBeforeAGapIsDropped() {
        let out = guarded(
            "Tink. Send the notes",
            [
                ("Tink.", 0.05, 0.2, 0.3), ("Send", 0.9, 1.1, 0.95), ("the", 1.1, 1.2, 0.9), ("notes", 1.2, 1.5, 0.9),
            ])
        #expect(out.text == "Send the notes")
        #expect(out.edits == [EditOp(stage: "filler", kind: .delete, fromText: "Tink.", toText: nil, wordDelta: -1, position: 0)])
    }

    @Test func anyShortTokenUnderFourLettersCanBeACue() {
        let out = guarded("Pop send it", [("Pop", 0.0, 0.1, 0.2), ("send", 0.8, 1.0, 0.9), ("it", 1.0, 1.1, 0.9)])
        #expect(out.text == "send it")
        let mm = guarded("Mm send it", [("Mm", 0.0, 0.1, 0.2), ("send", 0.8, 1.0, 0.9), ("it", 1.0, 1.1, 0.9)])
        #expect(mm.text == "send it")
    }

    @Test(arguments: ["I", "A", "OK", "No", "Yes", "Hi", "So", "We", "It", "He", "Oh", "Hey", "Do"])
    func realOpenersAreNeverDropped(_ opener: String) {
        let out = guarded("\(opener) think so", [(opener, 0.05, 0.2, 0.1), ("think", 0.9, 1.1, 0.9), ("so", 1.1, 1.2, 0.9)])
        #expect(out.text == "\(opener) think so")
        #expect(out.edits.isEmpty)
    }

    @Test func eachCueConditionIsNeeded() {
        let words: [(String, Double, Double, Float)] = [("Tink", 0.05, 0.2, 0.3), ("send", 0.9, 1.1, 0.9)]
        #expect(guarded("Tink send", words).text == "send")
        // Starts after the window.
        #expect(guarded("Tink send", [("Tink", 0.25, 0.4, 0.3), ("send", 1.0, 1.1, 0.9)]).text == "Tink send")
        // Confident.
        #expect(guarded("Tink send", [("Tink", 0.05, 0.2, 0.5), ("send", 0.9, 1.1, 0.9)]).text == "Tink send")
        // No gap.
        #expect(guarded("Tink send", [("Tink", 0.05, 0.2, 0.3), ("send", 0.39, 1.1, 0.9)]).text == "Tink send")
        #expect(guarded("Tink send", [("Tink", 0.05, 0.2, 0.3), ("send", 0.4, 1.1, 0.9)]).text == "send")
        // Four letters and not a known cue.
        #expect(guarded("Todo send", [("Todo", 0.05, 0.2, 0.3), ("send", 0.9, 1.1, 0.9)]).text == "Todo send")
    }

    @Test func aLoneCueSoundIsDroppedButALoneShortWordIsNot() {
        #expect(guarded("Ding", [("Ding", 0.05, 0.3, 0.3)]).isEmpty)
        #expect(guarded("Pop", [("Pop", 0.05, 0.3, 0.3)]).text == "Pop")
    }

    @Test func cueRuleNeedsTheTextToStartWithTheWord() {
        let out = guarded("Send the tink", [("Tink", 0.05, 0.2, 0.3), ("send", 0.9, 1.1, 0.9)])
        #expect(out.text == "Send the tink")
        #expect(out.edits.isEmpty)
    }

    @Test func cleanOffOnlyChecksEmptiness() {
        let t = transcription("[MUSIC] hello", [("[MUSIC]", 0.0, 0.1, 0.2), ("hello", 0.9, 1.0, 0.9)])
        let out = TranscriptGuard().apply(t, voicedMs: 900, clean: false)
        #expect(out.text == "[MUSIC] hello")
        #expect(out.edits.isEmpty)
        #expect(!out.isEmpty)
        #expect(TranscriptGuard().apply(t, voicedMs: 10, clean: false).isEmpty)
    }
}
