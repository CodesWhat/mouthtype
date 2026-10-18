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
}
