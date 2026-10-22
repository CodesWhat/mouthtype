import AppKit
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct CleanupSettingsTests {
    private func defaults() -> UserDefaults {
        let suite = "mouthtype.cleanup.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsAreLightEverythingOnAndFormal() {
        let settings = CleanupSettings.load(defaults())
        #expect(settings == CleanupSettings())
        #expect(settings.level == .light && settings.enabled)
        #expect(settings.enabled && settings.fillers && settings.spokenCommands && settings.numbers)
        #expect(settings.style == .formal && settings.styleName == "formal")
        #expect(settings.pipelineOptions == TextPipelineOptions())
    }

    @Test func slashCommandsAreOnWhenTheKeyIsAbsentAndRoundTrip() {
        let d = defaults()
        #expect(d.object(forKey: CleanupSettings.Key.slashCommands) == nil)
        #expect(CleanupSettings.load(d).slashCommands)
        var settings = CleanupSettings()
        settings.slashCommands = false
        settings.save(to: d)
        #expect(!CleanupSettings.load(d).slashCommands)
        #expect(!settings.pipelineOptions.slashCommands)
        #expect(CleanupSettings().pipelineOptions.slashCommands)
    }

    @Test func codingTargetsComeFromTheBundleIDOrTheSite() {
        for id in [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.jetbrains.intellij", "com.jetbrains.pycharm",
            "dev.zed.Zed", "com.anthropic.claudefordesktop", "com.openai.codex", "com.stablyai.orca",
        ] {
            #expect(CodingTargets.isCodingTarget(bundleID: id), Comment(rawValue: id))
        }
        for id in ["com.apple.Notes", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.jetbrainsfake.app", nil] {
            #expect(!CodingTargets.isCodingTarget(bundleID: id))
        }
        #expect(CodingTargets.isCodingTarget(bundleID: "com.google.Chrome", websiteHost: "claude.ai"))
        #expect(CodingTargets.isCodingTarget(bundleID: "com.apple.Safari", websiteHost: "chatgpt.com"))
        #expect(!CodingTargets.isCodingTarget(bundleID: "com.google.Chrome", websiteHost: "example.com"))
        #expect(!CodingTargets.isCodingTarget(bundleID: "com.google.Chrome", websiteHost: nil))
        // A host only counts in a browser that reports one.
        #expect(!CodingTargets.isCodingTarget(bundleID: "com.apple.Notes", websiteHost: "claude.ai"))
    }

    @Test func settingsRoundTrip() {
        let d = defaults()
        var settings = CleanupSettings()
        settings.fillers = false
        settings.numbers = false
        settings.style = StylePreset.veryCasual.options
        settings.save(to: d)
        #expect(CleanupSettings.load(d) == settings)
        #expect(settings.styleName == "veryCasual")
        #expect(settings.pipelineOptions.fillers == false && settings.pipelineOptions.spokenCommands)
    }

    @Test func theLevelRoundTripsAndEveryLevelIsStored() {
        for level in CleanupLevel.allCases {
            let d = defaults()
            var settings = CleanupSettings()
            settings.level = level
            settings.save(to: d)
            #expect(CleanupSettings.load(d).level == level)
            #expect(d.string(forKey: "cleanupLevel") == level.rawValue)
        }
    }

    @Test func anOldMasterSwitchOffBecomesTheOffLevel() {
        let d = defaults()
        d.set(false, forKey: "cleanupEnabled")
        #expect(CleanupSettings.load(d).level == .off)
        d.set("medium", forKey: "cleanupLevel")
        #expect(CleanupSettings.load(d).level == .medium)
        let fresh = defaults()
        fresh.set(true, forKey: "cleanupEnabled")
        #expect(CleanupSettings.load(fresh).level == .light)
    }

    @Test func onlyOffTurnsTheStagesOffAndTheModelLevelsRunThemAll() {
        var settings = CleanupSettings()
        for level in [CleanupLevel.basic, .light, .medium] {
            settings.level = level
            #expect(settings.pipelineOptions == TextPipelineOptions())
        }
        settings.level = .off
        #expect(settings.pipelineOptions == .none)
    }

    @Test func masterOffBypassesEveryStageAndStyle() {
        var settings = CleanupSettings()
        settings.level = .off
        settings.style = StylePreset.veryCasual.options
        #expect(settings.pipelineOptions == .none)
    }

    @Test(arguments: CleanupLevel.allCases, [false, true])
    func spokenCommandsAndListsFollowTheSameSwitch(level: CleanupLevel, enabled: Bool) {
        var settings = CleanupSettings()
        settings.level = level
        settings.spokenCommands = enabled
        let options = settings.pipelineOptions
        let expected = level != .off && enabled
        #expect(options.spokenCommands == expected)
        #expect(options.countedLists == expected)
        let prose = "First, call the bank. Second, email Priya."
        let result = TextPipeline().run(TextPipelineInput(text: prose, options: options))
        if expected {
            #expect(result.text.hasPrefix("1.") && result.text.contains("\n2."))
        } else {
            #expect(result.text == prose)
        }
    }

    @Test func aMixedStyleIsCustom() {
        var settings = CleanupSettings()
        settings.style = StyleOptions(capitalisation: .lowercase, endingPunctuation: .keep)
        #expect(settings.styleName == "custom")
    }

    // MARK: Menu

    private func submenu(_ section: CleanupMenuSection) -> NSMenu { section.items[0].submenu! }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem { menu.items.first { $0.title == title }! }

    private func click(_ item: NSMenuItem) {
        _ = item.target?.perform(item.action, with: item)
    }

    @Test func theMenuHasTheLevelStageAndToneItems() {
        let menu = submenu(CleanupMenuSection(defaults: defaults()))
        for title in [
            "Off", "Basic", "Fast", "Thorough", "Remove fillers", "Spoken commands and lists", "Format numbers", "Formal", "Casual",
            "Very casual", "Custom", "Lowercase sentence starts", "Drop final full stop",
        ] {
            #expect(menu.items.contains { $0.title == title }, "\(title)")
        }
        #expect(item(menu, "Fast").state == .on && item(menu, "Basic").state == .off)
        #expect(item(menu, "Formal").state == .on && item(menu, "Custom").state == .off)
    }

    @Test func choosingAPresetSetsTheSwitches() {
        let d = defaults()
        let section = CleanupMenuSection(defaults: d)
        let menu = submenu(section)
        click(item(menu, "Very casual"))
        #expect(CleanupSettings.load(d).style == StylePreset.veryCasual.options)
        #expect(item(menu, "Very casual").state == .on && item(menu, "Formal").state == .off)
        #expect(item(menu, "Lowercase sentence starts").state == .on && item(menu, "Drop final full stop").state == .on)
    }

    @Test func changingASwitchShowsCustom() {
        let d = defaults()
        let section = CleanupMenuSection(defaults: d)
        let menu = submenu(section)
        click(item(menu, "Lowercase sentence starts"))
        #expect(CleanupSettings.load(d).style == StyleOptions(capitalisation: .lowercase, endingPunctuation: .keep))
        #expect(item(menu, "Custom").state == .on && item(menu, "Formal").state == .off)
        click(item(menu, "Drop final full stop"))
        #expect(item(menu, "Very casual").state == .on && item(menu, "Custom").state == .off)
        click(item(menu, "Lowercase sentence starts"))
        #expect(item(menu, "Casual").state == .on && item(menu, "Very casual").state == .off)
        withExtendedLifetime(section) {}
    }

    @Test func theLevelsAreRadioItems() {
        let d = defaults()
        let section = CleanupMenuSection(defaults: d)
        let menu = submenu(section)
        click(item(menu, "Thorough"))
        #expect(CleanupSettings.load(d).level == .medium)
        #expect(["Off", "Basic", "Fast"].allSatisfy { item(menu, $0).state == .off } && item(menu, "Thorough").state == .on)
        click(item(menu, "Basic"))
        #expect(CleanupSettings.load(d).level == .basic && item(menu, "Basic").state == .on && item(menu, "Thorough").state == .off)
        withExtendedLifetime(section) {}
    }

    @Test func togglesPersistAndOffGreysTheRest() {
        let d = defaults()
        let section = CleanupMenuSection(defaults: d)
        let menu = submenu(section)
        click(item(menu, "Remove fillers"))
        #expect(CleanupSettings.load(d).fillers == false && item(menu, "Remove fillers").state == .off)
        click(item(menu, "Off"))
        #expect(CleanupSettings.load(d).enabled == false)
        #expect(!item(menu, "Remove fillers").isEnabled && !item(menu, "Casual").isEnabled)
        #expect(item(menu, "Fast").isEnabled)
        withExtendedLifetime(section) {}
    }
}
