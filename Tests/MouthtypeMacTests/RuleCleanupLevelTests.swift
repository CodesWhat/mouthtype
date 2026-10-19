import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct RuleCleanupLevelTests {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "rule-cleanup-level-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private let chrome = "com.google.Chrome"

    @Test func siteBeatsAppBeatsDefaultForLevelAndToneTogether() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: chrome, appName: "Chrome", style: StylePreset.casual.options, level: .basic)
        try styles.setWebsite(domain: "slack.com", style: StylePreset.veryCasual.options, level: .medium)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "work.slack.com") == .medium)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "work.slack.com", fallback: .formal) == StylePreset.veryCasual.options)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "example.org") == .basic)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "example.org", fallback: .formal) == StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: chrome) == .basic)
    }

    @Test func nilFieldsFallThroughAndNoRuleLeavesTheGlobalLevel() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: chrome, appName: "Chrome", style: StylePreset.casual.options, level: .off)
        try styles.setWebsite(domain: "slack.com", style: nil, level: .light)
        try styles.setWebsite(domain: "docs.example.com", style: StylePreset.veryCasual.options, level: nil)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "app.slack.com") == .light)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "app.slack.com", fallback: .formal) == StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "docs.example.com") == .off)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "docs.example.com", fallback: .formal) == StylePreset.veryCasual.options)
        #expect(styles.resolveLevel(bundleID: "org.example.other", websiteHost: "app.slack.com") == nil)
        #expect(AppCleanupStyles().resolveLevel(bundleID: chrome, websiteHost: "slack.com") == nil)
    }

    @Test func websiteRulesOnlyApplyInSupportedBrowsers() throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "slack.com", style: nil, level: .off)
        #expect(styles.resolveLevel(bundleID: "com.apple.Terminal", websiteHost: "slack.com") == nil)
    }

    @Test func aRuleWithNeitherToneNorLevelIsRemoved() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: nil, level: .off)
        #expect(styles.entries.first?.style == nil && styles.entries.first?.level == .off)
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: nil, level: nil)
        #expect(styles.entries.isEmpty)
        try styles.setWebsite(domain: "slack.com", style: .formal, level: .off)
        try styles.setWebsite(domain: "slack.com", style: nil, level: nil)
        #expect(styles.websites.isEmpty)
    }

    @Test func levelsRoundTripThroughPreferences() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Terminal", appName: "Terminal", style: nil, level: .off)
        try styles.set(bundleID: chrome, appName: "Chrome", style: StylePreset.casual.options, level: .medium)
        try styles.setWebsite(domain: "slack.com", style: nil, level: .light)
        try styles.setWebsite(domain: "mail.example.com", style: .formal, level: .basic)
        try styles.save(to: d)
        let saved = try AppCleanupStyles.load(d)
        #expect(saved == styles)
        #expect(saved.resolveLevel(bundleID: "com.apple.Terminal") == .off)
        #expect(saved.entries.first { $0.bundleID == "com.apple.Terminal" }?.style == nil)
        #expect(saved.websites.first { $0.domain == "slack.com" }?.level == .light)
    }

    @Test func rulesSavedBeforeCleanupLevelsDecodeWithNoLevel() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let old = """
        {"version":1,"entries":[{"bundleID":"com.apple.MobileSMS","appName":"Messages","capitalisation":"sentence","endingPunctuation":"dropFinalFullStop"}],\
        "websites":[{"domain":"slack.com","capitalisation":"lowercase","endingPunctuation":"keep"}]}
        """
        d.set(Data(old.utf8), forKey: AppCleanupStyles.preferenceKey)
        let styles = try AppCleanupStyles.load(d)
        #expect(styles.entries.count == 1 && styles.entries[0].level == nil && styles.entries[0].style != nil)
        #expect(styles.websites.count == 1 && styles.websites[0].level == nil && styles.websites[0].style != nil)
        #expect(styles.resolveLevel(bundleID: "com.apple.MobileSMS") == nil)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "slack.com") == nil)
    }

    @Test func unreadableLevelOrEmptyRuleIsKeptIntactAndRejected() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let documents = [
            #"{"version":1,"entries":[{"bundleID":"a.b","appName":"A","capitalisation":"sentence","endingPunctuation":"keep","cleanupLevel":"turbo"}]}"#,
            #"{"version":1,"entries":[{"bundleID":"a.b","appName":"A"}]}"#,
            #"{"version":1,"entries":[{"bundleID":"a.b","appName":"A","capitalisation":"sentence","cleanupLevel":"off"}]}"#,
        ]
        for document in documents {
            let data = Data(document.utf8)
            d.set(data, forKey: AppCleanupStyles.preferenceKey)
            #expect(throws: (any Error).self) { try AppCleanupStyles.load(d) }
            #expect(d.data(forKey: AppCleanupStyles.preferenceKey) == data)
        }
    }

    @MainActor
    @Test func settingsModelKeepsTheOtherFieldWhenOneChanges() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let model = SettingsModel(defaults: d)
        model.setAppStyle(bundleID: "com.apple.Terminal", appName: "Terminal", tone: .casual)
        model.setAppCleanupLevel(bundleID: "com.apple.Terminal", appName: "Terminal", level: .off)
        #expect(model.appStyles.entries.first?.style == StylePreset.casual.options && model.appStyles.entries.first?.level == .off)
        model.setAppStyle(bundleID: "com.apple.Terminal", appName: "Terminal", tone: nil)
        #expect(model.appStyles.entries.first?.style == nil && model.appStyles.entries.first?.level == .off)
        model.setAppCleanupLevel(bundleID: "com.apple.Terminal", appName: "Terminal", level: nil)
        #expect(model.appStyles.entries.isEmpty)

        model.addWebsiteRule(domain: "slack.com", tone: .formal, level: .medium)
        model.setWebsiteStyle(domain: "slack.com", tone: .casual)
        #expect(model.appStyles.websites.first?.level == .medium)
        model.setWebsiteStyle(domain: "slack.com", tone: nil)
        #expect(model.appStyles.websites.first?.style == nil && model.appStyles.websites.first?.level == .medium)
        model.setWebsiteCleanupLevel(domain: "slack.com", level: nil)
        #expect(model.appStyles.websites.isEmpty)
        #expect(try AppCleanupStyles.load(d).websites.isEmpty)
    }
}
