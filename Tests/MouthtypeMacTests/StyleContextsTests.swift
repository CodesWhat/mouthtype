import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct StyleContextsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "mouthtype.style-contexts.tests.\(UUID().uuidString)")!
    }

    private let casual = StylePreset.casual.options
    private let veryCasual = StylePreset.veryCasual.options

    // MARK: Built-ins

    @Test func builtInListsAndTonesMatchTheDesign() {
        let names = { (id: StyleContextID) in StyleContexts.builtIns(id).map(\.name) }
        #expect(names(.personal) == ["Messages", "WhatsApp", "Telegram", "Discord", "Signal"])
        #expect(names(.work) == ["Slack", "Microsoft Teams", "linkedin.com", "teams.microsoft.com"])
        #expect(names(.email) == ["Mail", "Outlook", "mail.google.com", "outlook.office.com"])
        #expect(names(.other).isEmpty)
        let contexts = StyleContexts()
        #expect(contexts.tone(.personal) == .casual && contexts.tone(.work) == .casual && contexts.tone(.email) == .formal)
        #expect(contexts.tone(.other) == nil)
        #expect(contexts.members(.other).isEmpty)
    }

    @Test func builtInBundleIdentifiers() {
        let contexts = StyleContexts()
        let expected: [(String, StyleContextID)] = [
            ("com.apple.MobileSMS", .personal), ("net.whatsapp.WhatsApp", .personal), ("ru.keepcoder.Telegram", .personal), ("com.tdesktop.Telegram", .personal), ("com.microsoft.teams", .work),
            ("com.hnc.Discord", .personal), ("org.whispersystems.signal-desktop", .personal),
            ("com.tinyspeck.slackmacgap", .work), ("com.microsoft.teams2", .work),
            ("com.apple.mail", .email), ("com.microsoft.Outlook", .email),
        ]
        for (bundleID, id) in expected { #expect(contexts.context(bundleID: bundleID) == id) }
        #expect(contexts.context(bundleID: "com.apple.Terminal") == nil)
        #expect(contexts.context(bundleID: nil) == nil)
    }

    // MARK: Resolution

    @Test func unlistedAppsAreOtherAndFollowTheDefaultTone() {
        let styles = AppCleanupStyles()
        #expect(styles.resolve(bundleID: "com.apple.Terminal", fallback: .formal) == .formal)
        #expect(styles.resolve(bundleID: "com.apple.Terminal", fallback: veryCasual) == veryCasual)
        #expect(styles.resolve(bundleID: nil, fallback: casual) == casual)
        #expect(styles.resolveLevel(bundleID: "com.apple.Terminal") == nil)
    }

    @Test func contextTonesApplyToTheirBuiltInApps() {
        let styles = AppCleanupStyles()
        #expect(styles.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == casual)
        #expect(styles.resolve(bundleID: "com.tinyspeck.slackmacgap", fallback: .formal) == casual)
        #expect(styles.resolve(bundleID: "com.apple.mail", fallback: veryCasual) == .formal)
    }

    @Test func websiteInAContextBeatsItsBrowser() {
        let styles = AppCleanupStyles()
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: veryCasual) == .formal)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "www.linkedin.com", fallback: .formal) == casual)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "example.org", fallback: veryCasual) == veryCasual)
        // A website is only read in a browser, so a non-browser app ignores the host.
        #expect(styles.resolve(bundleID: "com.apple.mail", websiteHost: "linkedin.com", fallback: .formal) == .formal)
    }

    @Test func websiteInAContextBeatsTheBrowsersOwnContext() throws {
        var styles = AppCleanupStyles()
        styles.contexts.addApp(.work, bundleID: "com.google.Chrome", appName: "Chrome")
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: nil, fallback: veryCasual) == casual)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: veryCasual) == .formal)
    }

    @Test func userRuleBeatsBuiltInAtTheSameLevel() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.MobileSMS", appName: "Messages", style: veryCasual)
        #expect(styles.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == veryCasual)
        try styles.setWebsite(domain: "mail.google.com", style: casual)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: .formal) == casual)
    }

    @Test func moreSpecificBuiltInBeatsABroaderUserWebsiteRule() throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "google.com", style: veryCasual)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: .formal) == .formal)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "docs.google.com", fallback: .formal) == veryCasual)
    }

    @Test func tonesAndLevelsFallThroughOnTheirOwn() throws {
        var styles = AppCleanupStyles()
        // A rule that only sets a level keeps the context's tone.
        try styles.set(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: nil, level: .basic)
        #expect(styles.resolve(bundleID: "com.tinyspeck.slackmacgap", fallback: .formal) == casual)
        #expect(styles.resolveLevel(bundleID: "com.tinyspeck.slackmacgap") == .basic)
        // A context level reaches its members; a rule's level beats it.
        styles.contexts.setLevel(.work, .medium)
        try styles.set(bundleID: "com.microsoft.teams2", appName: "Teams", style: nil, level: .off)
        #expect(styles.resolveLevel(bundleID: "com.tinyspeck.slackmacgap") == .basic)
        #expect(styles.resolveLevel(bundleID: "com.microsoft.teams2") == .off)
        styles.contexts.addApp(.work, bundleID: "org.example.Chat", appName: "Chat")
        #expect(styles.resolveLevel(bundleID: "org.example.Chat") == .medium)
        #expect(styles.resolveLevel(bundleID: "com.apple.mail") == nil)
    }

    @Test func otherLevelAppliesOnlyToUnlistedApps() {
        var styles = AppCleanupStyles()
        styles.contexts.setLevel(.other, .basic)
        #expect(styles.resolveLevel(bundleID: "com.apple.Terminal") == .basic)
        #expect(styles.resolveLevel(bundleID: nil) == .basic)
        #expect(styles.resolveLevel(bundleID: "com.apple.mail") == nil)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "mail.google.com") == nil)
        #expect(styles.enablesCleanup)
        styles.contexts.setLevel(.other, .off)
        #expect(!styles.enablesCleanup)
    }

    // MARK: Editing

    @Test func addingAnAppMovesItBetweenContexts() {
        var contexts = StyleContexts()
        contexts.addApp(.email, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        #expect(contexts.context(bundleID: "com.tinyspeck.slackmacgap") == .email)
        #expect(!contexts.members(.work).contains { $0.keys.contains("com.tinyspeck.slackmacgap") })
        #expect(contexts.members(.email).last?.name == "Slack" && contexts.members(.email).last?.isBuiltIn == true || contexts.members(.email).contains { $0.keys.contains("com.tinyspeck.slackmacgap") })
        // Moving it home restores the built-in entry without a duplicate.
        contexts.addApp(.work, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        #expect(contexts.context(bundleID: "com.tinyspeck.slackmacgap") == .work)
        #expect(contexts.isDefault)
    }

    @Test func removingABuiltInFallsBackToOther() {
        var contexts = StyleContexts()
        let discord = StyleContexts.builtIns(.personal).first { $0.name == "Discord" }!
        contexts.remove(discord, from: .personal)
        #expect(contexts.context(bundleID: "com.hnc.Discord") == nil)
        #expect(!contexts.members(.personal).contains(discord))
    }

    @Test func addedWebsitesAreNormalisedAndValidated() {
        var contexts = StyleContexts()
        let added = contexts.addSite(.personal, domain: " Web.WhatsApp.com. ")
        let rejected = contexts.addSite(.personal, domain: "https://x.com/path")
        #expect(added && !rejected)
        #expect(contexts.context(host: "web.whatsapp.com") == .personal)
        #expect(contexts.members(.personal).last == StyleMember(kind: .site, name: "web.whatsapp.com", keys: ["web.whatsapp.com"], isBuiltIn: false))
        // Moving a built-in site to another context takes it out of the first.
        let moved = contexts.addSite(.personal, domain: "linkedin.com")
        #expect(moved)
        #expect(contexts.context(host: "linkedin.com") == .personal)
        #expect(!contexts.members(.work).contains { $0.name == "linkedin.com" })
    }

    @Test func otherHasNoListAndRejectsMembers() {
        var contexts = StyleContexts()
        contexts.addApp(.other, bundleID: "com.apple.Terminal", appName: "Terminal")
        let other = contexts.addSite(.other, domain: "example.org")
        #expect(!other)
        contexts.setTone(.other, .formal)
        #expect(contexts.isDefault)
    }

    // MARK: Storage and migration

    @Test func contextsRoundTripAndDefaultsStoreNothing() throws {
        let d = defaults()
        var styles = try AppCleanupStyles.load(d)
        try styles.save(to: d)
        #expect(d.object(forKey: StyleContexts.preferenceKey) == nil)
        styles.contexts.setTone(.email, .casual)
        styles.contexts.setLevel(.other, .basic)
        styles.contexts.addApp(.personal, bundleID: "org.example.Chat", appName: "Chat")
        styles.contexts.addSite(.work, domain: "notion.so")
        styles.contexts.remove(StyleContexts.builtIns(.personal)[0], from: .personal)
        try styles.save(to: d)
        let loaded = try AppCleanupStyles.load(d)
        #expect(loaded == styles)
        #expect(loaded.contexts.tone(.email) == .casual && loaded.contexts.level(.other) == .basic)
        // Back to the built-ins removes the stored key.
        var reset = loaded
        reset.contexts = StyleContexts()
        try reset.save(to: d)
        #expect(d.object(forKey: StyleContexts.preferenceKey) == nil)
    }

    @Test func unreadableContextDataFallsBackToBuiltIns() throws {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: StyleContexts.preferenceKey)
        let styles = try AppCleanupStyles.load(d)
        #expect(styles.contexts.isDefault)
        #expect(styles.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == casual)
    }

    /// The format shipped before contexts: app and website rules, some with cleanup levels, some without.
    private let legacy = """
    {"version":1,"entries":[
      {"bundleID":"com.tinyspeck.slackmacgap","appName":"Slack","capitalisation":"sentence","endingPunctuation":"keep"},
      {"bundleID":"com.apple.Terminal","appName":"Terminal","cleanupLevel":"basic"},
      {"bundleID":"org.example.Notes","appName":"Notes","capitalisation":"lowercase","endingPunctuation":"dropFinalFullStop","cleanupLevel":"off"}],
     "websites":[{"domain":"linkedin.com","cleanupLevel":"light"},{"domain":"example.org","capitalisation":"sentence","endingPunctuation":"dropFinalFullStop"}]}
    """

    @Test func storedRulesMigrateLosslesslyAndKeepWorking() throws {
        let d = defaults()
        d.set(Data(legacy.utf8), forKey: AppCleanupStyles.preferenceKey)
        let styles = try AppCleanupStyles.load(d)
        #expect(Set(styles.entries.map(\.bundleID)) == ["org.example.Notes", "com.tinyspeck.slackmacgap", "com.apple.Terminal"])
        #expect(styles.entries.count == 3 && styles.websites.count == 2)
        // Nothing was rewritten, and saving back keeps every rule.
        try styles.save(to: d)
        let again = try AppCleanupStyles.load(d)
        #expect(again.entries == styles.entries && again.websites == styles.websites)
        #expect(d.object(forKey: StyleContexts.preferenceKey) == nil)

        // The Formal rule on Slack still beats the Work context's Casual; the level-only rules leave tones to the lists.
        #expect(styles.resolve(bundleID: "com.tinyspeck.slackmacgap", fallback: .formal) == .formal)
        #expect(styles.resolve(bundleID: "com.apple.Terminal", fallback: veryCasual) == veryCasual)
        #expect(styles.resolveLevel(bundleID: "com.apple.Terminal") == .basic)
        #expect(styles.resolve(bundleID: "org.example.Notes", fallback: .formal) == veryCasual)
        #expect(styles.resolveLevel(bundleID: "org.example.Notes") == .off)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "www.linkedin.com") == .light)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "www.linkedin.com", fallback: .formal) == casual)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "example.org", fallback: .formal) == casual)
    }

    @Test func legacyRulesShowOnTheirMemberRowOrUnderTheContextTheirToneMatches() throws {
        let d = defaults()
        d.set(Data(legacy.utf8), forKey: AppCleanupStyles.preferenceKey)
        let styles = try AppCleanupStyles.load(d)

        // Slack's own Formal rule stays on its Work row as an editable override.
        let work = StyleRows.rows(for: .work, in: styles)
        let slack = try #require(work.first { $0.member.name == "Slack" })
        #expect(slack.isBuiltIn && !slack.ownRule && slack.ruleStyle == .formal)
        let email = StyleRows.rows(for: .email, in: styles)
        #expect(!email.contains { $0.member.name == "Slack" })
        #expect(email.allSatisfy { $0.isBuiltIn })

        // example.org's Casual rule has no context of its own, so it lands in the first Casual one.
        let personal = StyleRows.rows(for: .personal, in: styles)
        #expect(personal.contains { $0.member.name == "example.org" && $0.ownRule })

        // A level on a built-in site shows on its row without taking it out of its list.
        let linkedin = try #require(work.first { $0.member.name == "linkedin.com" })
        #expect(linkedin.isBuiltIn && linkedin.ruleLevel == .light)

        // Rules no context claims stay editable on the Other tab, so no rule disappears.
        #expect(StyleRows.ownRules(in: styles).map(\.member.name).sorted() == ["Notes", "Terminal"])
    }

    @Test func everyStoredRuleAppearsExactlyOnceAcrossTheTabs() throws {
        let d = defaults()
        d.set(Data(legacy.utf8), forKey: AppCleanupStyles.preferenceKey)
        var styles = try AppCleanupStyles.load(d)
        // A level-only rule on a subdomain of a built-in site, and a tone rule on a listed app that differs from its context.
        try styles.setWebsite(domain: "jobs.linkedin.com", style: nil, level: .off)
        try styles.set(bundleID: "com.apple.mail", appName: "Mail", style: nil, level: .basic)
        styles.contexts.addApp(.personal, bundleID: "org.example.Added", appName: "Added")
        try styles.set(bundleID: "org.example.Added", appName: "Added", style: veryCasual, level: .medium)

        var appearances: [String: Int] = [:]
        for id in StyleContextID.allCases {
            for row in StyleRows.rows(for: id, in: styles) {
                if row.ruleStyle != nil || row.ruleLevel != nil { appearances[row.member.id, default: 0] += 1 }
            }
        }
        for rule in StyleRows.ownRules(in: styles) { appearances[rule.member.id, default: 0] += 1 }
        for entry in styles.entries { #expect(appearances["app:" + entry.bundleID] == 1, "\(entry.bundleID)") }
        for entry in styles.websites { #expect(appearances["site:" + entry.domain] == 1, "\(entry.domain)") }
        #expect(appearances["site:jobs.linkedin.com"] == 1)
    }
}
