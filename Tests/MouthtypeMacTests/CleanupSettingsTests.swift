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

    @Test func defaultsAreEverythingOnAndFormal() {
        let settings = CleanupSettings.load(defaults())
        #expect(settings == CleanupSettings())
        #expect(settings.enabled && settings.fillers && settings.spokenCommands && settings.numbers)
        #expect(settings.style == .formal && settings.styleName == "formal")
        #expect(settings.pipelineOptions == TextPipelineOptions())
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

    @Test func masterOffBypassesEveryStageAndStyle() {
        var settings = CleanupSettings()
        settings.enabled = false
        settings.style = StylePreset.veryCasual.options
        #expect(settings.pipelineOptions == .none)
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

    @Test func theMenuHasTheMasterStageAndToneItems() {
        let menu = submenu(CleanupMenuSection(defaults: defaults()))
        for title in [
            "Clean up dictation", "Remove fillers", "Spoken commands and lists", "Format numbers", "Formal", "Casual",
            "Very casual", "Custom", "Lowercase sentence starts", "Drop final full stop",
        ] {
            #expect(menu.items.contains { $0.title == title }, "\(title)")
        }
        #expect(item(menu, "Clean up dictation").state == .on)
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

    @Test func togglesPersistAndTheMasterGreysTheRest() {
        let d = defaults()
        let section = CleanupMenuSection(defaults: d)
        let menu = submenu(section)
        click(item(menu, "Remove fillers"))
        #expect(CleanupSettings.load(d).fillers == false && item(menu, "Remove fillers").state == .off)
        click(item(menu, "Clean up dictation"))
        #expect(CleanupSettings.load(d).enabled == false)
        #expect(!item(menu, "Remove fillers").isEnabled && !item(menu, "Casual").isEnabled)
        #expect(item(menu, "Clean up dictation").isEnabled)
        withExtendedLifetime(section) {}
    }
}
