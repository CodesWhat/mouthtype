import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct WebsiteCleanupStylesTests {
    @Test func domainRulesOverrideBrowserAndMostSpecificParentWins() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: StylePreset.casual.options)
        try styles.setWebsite(domain: "SLACK.COM", style: .formal)
        try styles.setWebsite(domain: "personal.slack.com", style: StylePreset.veryCasual.options)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "work.slack.com", fallback: .formal) == .formal)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "personal.slack.com", fallback: .formal) == StylePreset.veryCasual.options)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "evilslack.com", fallback: .formal) == StylePreset.casual.options)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: nil, fallback: .formal) == StylePreset.casual.options)
    }

    @Test func websiteRulesRoundTripAndLegacyPreferencesRemainReadable() throws {
        let suite = "website-style-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"version\":1,\"entries\":[]}".utf8), forKey: AppCleanupStyles.preferenceKey)
        var styles = try AppCleanupStyles.load(defaults)
        #expect(styles.websites.isEmpty)
        try styles.setWebsite(domain: " app.slack.com. ", style: .formal)
        try styles.save(to: defaults)
        #expect(try AppCleanupStyles.load(defaults) == styles)
        styles.removeWebsite(domain: "app.slack.com")
        #expect(styles.websites.isEmpty)
    }

    @Test func malformedDomainsAreRejectedWithoutMutation() throws {
        var styles = AppCleanupStyles()
        for domain in ["", "com", "https://slack.com", "slack.com/path", "*.slack.com", "a..com", "a.-com", "a.com:443", "user@a.com"] {
            #expect(throws: (any Error).self) { try styles.setWebsite(domain: domain, style: .formal) }
            #expect(styles.websites.isEmpty)
        }
    }

    @Test func browserDocumentURLPolicyHasNoFileOrWindowTitleFallback() {
        #expect(WebsiteContext.host(document: "https://work.slack.com/client?private=1", bundleID: "com.google.Chrome") == "work.slack.com")
        #expect(WebsiteContext.host(document: "https://mail.example.com", bundleID: "com.apple.Safari") == "mail.example.com")
        for document in ["file:///Users/example/private.html", "about:blank", "not a URL", "https://a.com@evil.example"] {
            #expect(WebsiteContext.host(document: document, bundleID: "com.google.Chrome") == nil)
        }
        #expect(WebsiteContext.host(document: "https://example.com", bundleID: "unknown.app") == nil)
    }

    // MARK: Legacy resolver semantics (the dev/v0.4.0 resolver, unchanged for rules made before contexts)

    @Test func subdomainRuleThatSetsOnlyToneDoesNotInheritParentDomainLevel() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: nil, level: .off)
        try styles.setWebsite(domain: "example.com", style: nil, level: .medium)
        try styles.setWebsite(domain: "chat.example.com", style: StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "chat.example.com") == CleanupLevel.off)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "www.example.com") == .medium)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "other.org") == CleanupLevel.off)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "chat.example.com", fallback: .formal) == StylePreset.casual.options)
    }

    @Test func subdomainRuleThatSetsOnlyLevelDoesNotInheritParentDomainTone() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: StylePreset.veryCasual.options)
        try styles.setWebsite(domain: "example.com", style: StylePreset.casual.options)
        try styles.setWebsite(domain: "jobs.example.com", style: nil, level: .basic)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "jobs.example.com", fallback: .formal) == StylePreset.veryCasual.options)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "jobs.example.com") == .basic)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "www.example.com", fallback: .formal) == StylePreset.casual.options)
    }

    @Test func websiteFieldsFallBackToAppThenDefault() throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "example.com", style: StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "example.com") == nil)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "example.com", fallback: .formal) == StylePreset.casual.options)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "nope.org", fallback: .formal) == .formal)
    }

    @Test func contextSiteBeatsBrowserRuleAndUserOverrideBeatsBuiltIn() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: StylePreset.veryCasual.options, level: .off)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: .formal) == .formal)
        try styles.setWebsite(domain: "mail.google.com", style: StylePreset.casual.options)
        #expect(styles.resolve(bundleID: "com.google.Chrome", websiteHost: "mail.google.com", fallback: .formal) == StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: "com.google.Chrome", websiteHost: "mail.google.com") == CleanupLevel.off)
    }

    @Test func hasWebsiteRulesCountsContextSites() throws {
        #expect(AppCleanupStyles().hasWebsiteRules)
        var styles = AppCleanupStyles()
        for site in StyleContexts.builtIns(.work).filter({ $0.kind == .site }) + StyleContexts.builtIns(.email).filter({ $0.kind == .site }) {
            styles.contexts.remove(site, from: .work)
            styles.contexts.remove(site, from: .email)
        }
        #expect(!styles.hasWebsiteRules)
        styles.contexts.addSite(.personal, domain: "example.org")
        #expect(styles.hasWebsiteRules)
    }
}
