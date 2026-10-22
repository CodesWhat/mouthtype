import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// Anything the user configured beats a built-in context default.
@Suite struct StylePrecedenceTests {
    private let chrome = "com.google.Chrome"
    private let veryCasual = StylePreset.veryCasual.options
    private let casual = StylePreset.casual.options

    @Test func chromeToneWithALevelOnlyGmailRuleKeepsTheChromeTone() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: chrome, appName: "Chrome", style: veryCasual)
        try styles.setWebsite(domain: "mail.google.com", style: nil, level: .basic)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "mail.google.com", fallback: .formal) == veryCasual)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "mail.google.com") == .basic)
    }

    @Test func aSavedParentDomainToneBeatsTheBuiltInGmailContext() throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "google.com", style: veryCasual)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "mail.google.com", fallback: .formal) == veryCasual)
    }

    @Test func aUserAppRuleBeatsTheBuiltInSiteContext() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: chrome, appName: "Chrome", style: veryCasual)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "mail.google.com", fallback: .formal) == veryCasual)
        // With no rule of yours, the built-in context still applies.
        #expect(AppCleanupStyles().resolve(bundleID: chrome, websiteHost: "mail.google.com", fallback: veryCasual) == .formal)
    }

    @Test func chromeOffWithNestedWebsiteRules() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: chrome, appName: "Chrome", style: nil, level: .off)
        try styles.setWebsite(domain: "example.com", style: nil, level: .basic)
        try styles.setWebsite(domain: "chat.example.com", style: casual, level: nil)
        // Only the most specific website rule counts, so chat.example.com does not inherit example.com's level.
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "chat.example.com") == .off)
        #expect(styles.resolve(bundleID: chrome, websiteHost: "chat.example.com", fallback: .formal) == casual)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: "www.example.com") == .basic)
        #expect(styles.resolveLevel(bundleID: chrome, websiteHost: nil) == .off)
    }

    // MARK: Old resolver against the new one

    /// The resolver as it was before contexts existed.
    private func oldResolve(_ styles: AppCleanupStyles, bundleID: String?, host: String?) -> (StyleOptions?, CleanupLevel?) {
        var site: WebsiteCleanupStyle?
        if let host = host.flatMap(AppCleanupStyles.normalizedDomain), WebsiteContext.supports(bundleID: bundleID) {
            site = styles.websites.filter { host == $0.domain || host.hasSuffix("." + $0.domain) }.max { $0.domain.count < $1.domain.count }
        }
        let app = styles.entries.first { $0.bundleID == bundleID }
        return (site?.style ?? app?.style, site?.level ?? app?.level)
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    @Test func legacyRuleSetsResolveLikeTheOriginalResolver() throws {
        var rng = Generator(state: 42)
        let apps = [chrome, "com.apple.Safari", "com.apple.Terminal", "com.tinyspeck.slackmacgap", "com.apple.mail"]
        let domains = ["example.com", "chat.example.com", "google.com", "mail.google.com", "docs.google.com", "linkedin.com", "other.org"]
        let hosts = domains + ["www.example.com", "a.b.chat.example.com", "jobs.linkedin.com", "unrelated.net"]
        let tones: [StyleOptions?] = [nil, veryCasual, casual, StylePreset.formal.options]
        let levels: [CleanupLevel?] = [nil, .off, .basic, .medium]
        var comparisons = 0
        for _ in 0..<300 {
            var styles = AppCleanupStyles()
            for app in apps where Bool.random(using: &rng) {
                try styles.set(bundleID: app, appName: "App", style: tones.randomElement(using: &rng)!, level: levels.randomElement(using: &rng)!)
            }
            for domain in domains where Bool.random(using: &rng) {
                try styles.setWebsite(domain: domain, style: tones.randomElement(using: &rng)!, level: levels.randomElement(using: &rng)!)
            }
            for app in apps + [nil] {
                for host in hosts.map(Optional.some) + [nil] {
                    let (oldStyle, oldLevel) = oldResolve(styles, bundleID: app, host: host)
                    let newStyle = styles.resolve(bundleID: app, websiteHost: host, fallback: .formal)
                    let newLevel = styles.resolveLevel(bundleID: app, websiteHost: host)
                    // Where a legacy rule answers, the answer is unchanged. Where none does, only a built-in context may fill in.
                    if let oldStyle { #expect(newStyle == oldStyle, "\(String(describing: app)) \(String(describing: host))") }
                    if let oldLevel { #expect(newLevel == oldLevel, "\(String(describing: app)) \(String(describing: host))") }
                    if oldStyle == nil, styles.contexts.context(bundleID: app) == nil,
                        WebsiteContext.supports(bundleID: app) == false || styles.contexts.context(host: host) == nil
                    {
                        #expect(newStyle == .formal)
                    }
                    if oldLevel == nil, styles.contexts.context(bundleID: app) == nil,
                        WebsiteContext.supports(bundleID: app) == false || styles.contexts.context(host: host) == nil
                    {
                        #expect(newLevel == nil)
                    }
                    comparisons += 1
                }
            }
        }
        #expect(comparisons > 10_000)
    }
}
