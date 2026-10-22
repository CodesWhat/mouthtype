import Testing
@testable import MouthtypeCore

@Suite struct NearbyNameGuardTests {
    @Test(
        arguments: [
            ("the meeting is with geoff", "The meeting is with Geoff Smith.", "Recipients: Jeff Smith\n"),
            ("send the note to geoff today", "Send the note to Geoff Smith today.", "Recipients: Jeff Smith\n"),
            ("geoff is ready", "Geoff Smith is ready.", "Recipients: Jeff Smith\n"),
            ("I have geoff's notes", "I have Geoff Smith’s notes.", "Recipients: Jeff Smith\n"),
            ("send it to ana", "Send it to Ana García.", "Recipients: Ana García\n"),
        ], [false, true])
    func rejectsAnInsertedNearbySurname(item: (String, String, String), native: Bool) async {
        let cleaner = FakeCleaner(returning: item.1)
        cleaner.usesNativeControls = native
        let result = await SmartCleanup(cleaner: cleaner, budget: { _ in .seconds(2) }).run(
            SmartCleanupRequest(text: item.0, level: .light, context: InsertionContext(before: item.2)))
        #expect(result.outcome == .guardRejected)
        #expect(result.text == item.0)
        #expect(result.rejection?.hasSuffix(" added") == true)
    }

    @Test(arguments: [
        ("the meeting is with geoff", "The meeting is with Jeff.", ["Jeff", "Smith"]),
        ("the meeting is with geoff smith", "The meeting is with Geoff Smith.", ["Jeff", "Smith"]),
        ("send it to jean luc", "Send it to Jean-Luc.", ["Jean-Luc"]),
        ("send it to ana garcia", "Send it to Ana García.", ["Ana", "García"]),
        ("um the meeting is with geoff", "The meeting is with Jeff.", ["Jeff", "Smith"]),
        ("send it to geoff actually jeff", "Send it to Jeff.", ["Jeff", "Smith"]),
    ])
    func preservesSpellingCorrectionsAndDictatedNames(item: (String, String, [String])) {
        #expect(
            SmartCleanupGuard.rejection(
                input: item.0, output: item.1, level: .light,
                nearbySpellings: item.2) == nil)
    }

    @Test func rejectsDuplicateNamesWithoutBlockingSpellingCorrections() {
        #expect(
            SmartCleanupGuard.rejection(
                input: "I met smith", output: "I met Smith Smith.",
                level: .medium, nearbySpellings: ["Smith"]) == "nearby spelling \"smith\" added")
        #expect(
            SmartCleanupGuard.rejection(
                input: "I met smith and smith", output: "I met Smith and Smith.",
                level: .medium, nearbySpellings: ["Smith"]) == nil)
        #expect(
            SmartCleanupGuard.rejection(
                input: "I met smith", output: "I met Smyth.",
                level: .medium, nearbySpellings: ["Smyth"]) == nil)
    }

    @Test func appliesAtTheTakeWordLimit() {
        let input = (Array(repeating: "word", count: SmartCleanup.maxWords - 1) + ["geoff"]).joined(separator: " ")
        #expect(
            SmartCleanupGuard.rejection(
                input: input, output: input + " Smith", level: .light,
                nearbySpellings: ["Jeff", "Smith"]) == "nearby spelling \"smith\" added")
    }

    @Test(arguments: ["um", "uh", "hmm", ",", "..."])
    func fillerCannotStandInForAnUnspokenSurname(filler: String) {
        #expect(
            SmartCleanupGuard.rejection(
                input: "I met Geoff \(filler)", output: "I met Geoff Smith.",
                level: .light, nearbySpellings: ["Jeff", "Smith"]) == "nearby spelling \"smith\" added")
        #expect(
            SmartCleanupGuard.rejection(
                input: "I met Geoff ER", output: "I met Geoff ER.",
                level: .light, nearbySpellings: ["Jeff", "ER"]) == nil)
    }

}
