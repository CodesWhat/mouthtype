import Testing
@testable import MouthtypeCore

@Suite struct SmartLiteralPreservationTests {
    @Test(
        arguments: [
            ("send this to `merry`", "Send this to Mary."),
            ("send this to jon@example.com", "Send this to john@example.com."),
            ("send this to jon/reports", "Send this to John/reports."),
            ("send this to /jon/reports", "Send this to jon/reports."),
            ("open https://example.com/jon", "Open https://example.com/john."),
            ("use `merry berry` here", "Use `merry Barry` here."),
            ("send this to jon@example.com", "Send this to xjon@example.com."),
            ("send this to jon@example.com after lunch actually tomorrow", "Send this after lunch actually tomorrow."),
            ("send this to jon@example.com actually ship it tomorrow", "Send this actually ship it tomorrow."),
        ], [CleanupLevel.light, .medium])
    func literalChangesAreRejected(item: (String, String), level: CleanupLevel) {
        #expect(SmartCleanupGuard.rejection(input: item.0, output: item.1, level: level) != nil)
    }

    @Test(
        arguments: [
            ("Run ./dusting --mode testing.", "Run /dusting --mode testing."),
            ("Open ../notes.txt", "Open ./notes.txt"),
            ("Open ../../notes.txt", "Open /notes.txt"),
            ("Open .gitignore now.", "Open.gitignore now."),
            ("The label says \"dusting\".", "The label says \"dusting.\""),
            ("The label says “dusting”.", "The label says “dusting.”"),
            ("Use \"mark\" here.", "Use \"Mark\" here."),
            ("Select \"merry\" in the list.", "Select \"Mary\" in the list."),
            ("She said \"Ready?\"", "She said \"Ready.\""),
        ], [false, true])
    func changedRelativePathsAndQuotedLabelsFallBackToTheCurrentTake(item: (String, String), native: Bool) async {
        let cleaner = FakeCleaner(returning: item.1)
        cleaner.usesNativeControls = native
        let result = await SmartCleanup(cleaner: cleaner).run(SmartCleanupRequest(text: item.0, level: .light))
        #expect(result.outcome == .guardRejected)
        #expect(result.text == item.0)
    }

    @Test(arguments: [
        ("The label says \"dusting\".", "The label says “dusting”."),
        ("The label says “dusting”.", "The label says \"dusting\"."),
        ("Use \"old\" actually \"new\"", "Use \"new\""),
        ("I'm testing this", "I'm testing this."),
        ("Use a 6\" screw and a 4\" bolt.", "Use a 6-inch screw and a 4-inch bolt."),
        ("Open ./notes.txt", "Open ./notes.txt."),
        ("Use .5 seconds.", "Use .5 seconds."),
        ("Wait...now do this.", "Wait…now do this."),
    ])
    func unchangedLabelsQuoteStylingAndExplicitCorrectionsAreAllowed(item: (String, String)) async {
        let result = await SmartCleanup(cleaner: FakeCleaner(returning: item.1))
            .run(SmartCleanupRequest(text: item.0, level: .light))
        #expect(result.outcome == .ok && result.text == item.1)
    }

    @Test(arguments: [
        ("send this to jon@example.com", "Send this to jon@example.com."),
        ("open /jon/reports, please", "Open /jon/reports, please."),
        ("use `merry berry` here", "Use `merry berry` here."),
        ("use `old` actually `new`", "Use `new`."),
        ("send to old@example.com actually new@example.com", "Send to new@example.com."),
    ])
    func unchangedLiteralsAndExplicitCorrectionsAreAccepted(item: (String, String)) {
        #expect(SmartCleanupGuard.rejection(input: item.0, output: item.1, level: .light) == nil)
    }

    @Test(
        arguments: [
            ("send this to `merry`", "Send this to Mary."),
            ("send this to jon@example.com", "Send this to john@example.com."),
            ("send this to jon/reports", "Send this to John/reports."),
        ], [false, true])
    func rejectedNameRewritesKeepTheOriginalLiteral(item: (String, String), native: Bool) async {
        let cleaner = FakeCleaner(returning: item.1)
        cleaner.usesNativeControls = native
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(
                text: item.0, level: .light, context: InsertionContext(before: "Recipients: Mary Jensen, John Smith\n")))
        #expect(result.outcome == .guardRejected)
        #expect(result.text == item.0)
    }
}
