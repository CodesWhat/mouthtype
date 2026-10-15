import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PasteMenuTests {
    @Test func shortcutMenuSavesForTheAppNamedWhenTheMenuOpened() throws {
        let name = "PasteMenuTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var front: (bundleID: String, name: String)? = ("com.example.editor", "Editor")
        let section = PasteMenuSection(defaults: defaults, frontApp: { front })
        let menu = try #require(section.items.first?.submenu)
        let shortcut = try #require(menu.items.first { $0.title == "Paste Shortcut for Editor" }?.submenu)
        let controlShift = try #require(shortcut.items.first { $0.title == "Control-Shift-V" })
        front = ("com.example.other", "Other")
        _ = controlShift.target?.perform(controlShift.action, with: controlShift)
        #expect(PasteSettings.chord(for: "com.example.editor", defaults: defaults) == .controlShiftV)
        #expect(PasteSettings.chord(for: "com.example.other", defaults: defaults) == .commandV)
        front = ("com.example.editor", "Editor")
        section.refresh()
        #expect(controlShift.state == .on)
        front = nil
        section.refresh()
        #expect(shortcut.items.allSatisfy { !$0.isEnabled })
    }

    @Test func toggleUsesTheCapturedTerminalAndShowsItsSavedState() throws {
        let name = "PasteMenuTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var front = (bundleID: "com.apple.Terminal", name: "Terminal")
        let section = PasteMenuSection(defaults: defaults, frontApp: { front })
        let submenu = try #require(section.items.first?.submenu)
        let toggle = try #require(submenu.items.first { $0.title == "Split Long Pastes in Terminal" })
        #expect(toggle.isEnabled && toggle.state == .off)
        front = ("com.example.browser", "Browser")
        _ = toggle.target?.perform(toggle.action, with: toggle)
        #expect(PasteSettings.chunksEnabled("com.apple.Terminal", defaults: defaults))
        section.refresh()
        #expect(!toggle.isEnabled)
        front = ("com.apple.Terminal", "Terminal")
        section.refresh()
        #expect(toggle.isEnabled && toggle.state == .on)
    }
}
