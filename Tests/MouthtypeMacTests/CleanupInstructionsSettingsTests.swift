import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct CleanupInstructionsSettingsTests {
    private func defaults() -> UserDefaults {
        let suite = "mouthtype.instructions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func model(_ defaults: UserDefaults? = nil) -> SettingsModel {
        SettingsModel(defaults: defaults ?? self.defaults())
    }

    // MARK: Presets

    @Test func startFromReplacesTheBoxWithThePresetText() {
        for preset in CleanupInstructionPresets.all {
            #expect(StyleInstructionsEditor.draft(startingFrom: preset) == preset.text)
        }
    }

    // MARK: Rules

    @Test func appAndWebsiteInstructionsRoundTrip() throws {
        let d = defaults()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: StylePreset.casual.options, instructions: "Short and direct.")
        try styles.setWebsite(domain: "mail.google.com", style: nil, level: .medium, instructions: "Greeting on its own line.")
        try styles.save(to: d)
        let saved = try AppCleanupStyles.load(d)
        #expect(saved == styles)
        #expect(saved.entries.first?.instructions == "Short and direct.")
        #expect(saved.websiteRule(domain: "mail.google.com")?.instructions == "Greeting on its own line.")
    }

    @Test func aRuleThatOnlyHoldsInstructionsIsKeptAndClearingItRemovesTheRule() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: nil, instructions: "Warm.")
        #expect(styles.entries.count == 1 && styles.entries[0].style == nil && styles.entries[0].level == nil)
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: nil, instructions: "   ")
        #expect(styles.entries.isEmpty)
        try styles.setWebsite(domain: "slack.com", style: nil, instructions: "Warm.")
        #expect(styles.websites.count == 1)
        try styles.setWebsite(domain: "slack.com", style: nil, instructions: nil)
        #expect(styles.websites.isEmpty)
    }

    @Test func instructionsAreCappedAtFiveHundredCharactersWhenSaved() throws {
        let d = defaults()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: .formal, instructions: String(repeating: "a", count: 900))
        #expect(styles.entries[0].instructions?.count == 500)
        try styles.save(to: d)
        #expect(try AppCleanupStyles.load(d).entries[0].instructions?.count == 500)
    }

    @Test func excitedRoundTripsAndOlderRecordsStillLoad() throws {
        let d = defaults()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: StylePreset.excited.options)
        try styles.setWebsite(domain: "slack.com", style: StylePreset.casual.options)
        try styles.save(to: d)
        let saved = try AppCleanupStyles.load(d)
        #expect(saved == styles)
        #expect(saved.resolve(bundleID: "org.example.chat", fallback: .formal) == StylePreset.excited.options)
        #expect(saved.resolve(bundleID: "org.example.chat", fallback: .formal).preset == .excited)
        #expect(saved.websiteRule(domain: "slack.com")?.style?.excited == false)

        let old = #"{"version":1,"entries":[{"bundleID":"org.example.old","appName":"Old","capitalisation":"sentence","endingPunctuation":"keep"}]}"#
        d.set(Data(old.utf8), forKey: AppCleanupStyles.preferenceKey)
        let loaded = try AppCleanupStyles.load(d)
        #expect(loaded.entries[0].style == .formal && loaded.entries[0].instructions == nil)
    }

    @Test func anExcitedFlagWithoutATonePairIsUnreadable() {
        let d = defaults()
        let bad = #"{"version":1,"entries":[{"bundleID":"org.example.old","appName":"Old","cleanupLevel":"medium","excited":true}]}"#
        d.set(Data(bad.utf8), forKey: AppCleanupStyles.preferenceKey)
        #expect(throws: (any Error).self) { try AppCleanupStyles.load(d) }
    }

    @Test func aContextCanHoldTheExcitedTone() {
        var contexts = StyleContexts()
        contexts.setTone(.personal, .excited)
        #expect(contexts.tone(.personal) == .excited)
        #expect(contexts.tone(.work) == .casual)
    }

    // MARK: Resolution

    @Test func aWebsiteRuleBeatsTheAppRuleAndFallsThroughWhenItHasNone() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: nil, instructions: "App words.")
        try styles.setWebsite(domain: "mail.google.com", style: nil, instructions: "Site words.")
        try styles.setWebsite(domain: "docs.google.com", style: StylePreset.casual.options)
        #expect(styles.resolveInstructions(bundleID: "com.google.Chrome", websiteHost: "mail.google.com") == "Site words.")
        #expect(styles.resolveInstructions(bundleID: "com.google.Chrome", websiteHost: "docs.google.com") == "App words.")
        #expect(styles.resolveInstructions(bundleID: "com.google.Chrome") == "App words.")
        #expect(styles.resolveInstructions(bundleID: "org.example.other", websiteHost: "mail.google.com") == nil)
        #expect(AppCleanupStyles().resolveInstructions(bundleID: "com.google.Chrome") == nil)
    }

    // MARK: Global setting

    @Test func globalInstructionsPersistNormalizedAndAreRemovedWhenEmpty() {
        let d = defaults()
        var settings = CleanupSettings()
        settings.instructions = "  Keep it\nwarm.  "
        settings.style = StylePreset.excited.options
        settings.save(to: d)
        let loaded = CleanupSettings.load(d)
        #expect(loaded.instructions == "Keep it warm.")
        #expect(loaded.style == StylePreset.excited.options && loaded.styleName == "excited")
        settings.instructions = ""
        settings.save(to: d)
        #expect(d.object(forKey: CleanupSettings.Key.instructions) == nil)
        #expect(CleanupSettings.load(d).instructions.isEmpty)
    }

    @Test func aStoredValueOverTheCapIsCutOnLoad() {
        let d = defaults()
        d.set(String(repeating: "z", count: 900), forKey: CleanupSettings.Key.instructions)
        #expect(CleanupSettings.load(d).instructions.count == 500)
    }

    @Test func defaultsHaveNoInstructionsAndNoExcitedTone() {
        let settings = CleanupSettings.load(defaults())
        #expect(settings.instructions.isEmpty && !settings.style.excited)
    }

    @Test func theModelSavesGlobalInstructionsAndTheExcitedToneToDefaults() {
        let d = defaults()
        let m = model(d)
        m.setInstructions(String(repeating: "q", count: 700))
        m.setTone(.excited)
        #expect(m.cleanup.instructions.count == 500)
        #expect(m.cleanup.style.preset == .excited)
        let reloaded = CleanupSettings.load(d)
        #expect(reloaded.instructions.count == 500 && reloaded.style.preset == .excited)
        m.setInstructions("")
        #expect(m.cleanup.instructions.isEmpty)
    }

    // MARK: Model edits keep each other

    @Test func changingToneOrLevelKeepsAnAppsInstructions() {
        let m = model()
        m.setAppInstructions(bundleIDs: ["org.example.chat"], appName: "Chat", instructions: "Warm.")
        m.setAppStyle(bundleID: "org.example.chat", appName: "Chat", tone: .excited)
        m.setAppCleanupLevel(bundleID: "org.example.chat", appName: "Chat", level: .medium)
        let rule = m.appStyles.entries.first
        #expect(rule?.instructions == "Warm." && rule?.style?.preset == .excited && rule?.level == .medium)
        m.setAppStyle(bundleIDs: ["org.example.chat"], appName: "Chat", tone: nil)
        m.setAppCleanupLevel(bundleIDs: ["org.example.chat"], appName: "Chat", level: nil)
        #expect(m.appStyles.entries.first?.instructions == "Warm.")
        m.setAppInstructions(bundleIDs: ["org.example.chat"], appName: "Chat", instructions: nil)
        #expect(m.appStyles.entries.isEmpty)
    }

    @Test func changingASiteToneOrLevelKeepsItsInstructionsAndInstructionsKeepTheTone() {
        let m = model()
        m.setWebsiteStyle(domain: "slack.com", tone: .casual)
        m.setWebsiteInstructions(domain: "slack.com", instructions: "Short.")
        m.setWebsiteCleanupLevel(domain: "slack.com", level: .medium)
        m.setWebsiteStyle(domain: "slack.com", tone: .excited)
        let rule = m.appStyles.websiteRule(domain: "slack.com")
        #expect(rule?.instructions == "Short." && rule?.style?.preset == .excited && rule?.level == .medium)
        m.addWebsiteRule(domain: "slack.com", tone: .formal, level: nil)
        #expect(m.appStyles.websiteRule(domain: "slack.com")?.instructions == "Short.")
    }

    @Test func addingAnAppToAContextKeepsInstructionsYouWrote() {
        let m = model()
        m.setAppStyle(bundleID: "org.example.chat", appName: "Chat", tone: .formal)
        m.setAppInstructions(bundleIDs: ["org.example.chat"], appName: "Chat", instructions: "Warm.")
        m.addContextApp(.personal, bundleID: "org.example.chat", appName: "Chat")
        let rule = m.appStyles.entries.first
        #expect(rule?.instructions == "Warm." && rule?.style == nil)
        #expect(m.appStyles.contexts.context(bundleID: "org.example.chat") == .personal)
    }

    @Test func rowsAndOwnRulesShowTheirInstructions() {
        let m = model()
        m.setAppInstructions(bundleIDs: ["ru.keepcoder.Telegram"], appName: "Telegram", instructions: "Warm.")
        m.setAppInstructions(bundleIDs: ["org.example.other"], appName: "Other app", instructions: "Plain.")
        let rows = StyleRows.rows(for: .personal, in: m.appStyles, installed: { $0 == "ru.keepcoder.Telegram" })
        #expect(rows.first { $0.member.name == "Telegram" }?.ruleInstructions == "Warm.")
        #expect(StyleRows.ownRules(in: m.appStyles).first { $0.member.name == "Other app" }?.instructions == "Plain.")
    }
}
