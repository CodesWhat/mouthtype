import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PasteMenuTests {
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
