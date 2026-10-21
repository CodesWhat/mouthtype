import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct DockPresenceTests {
    private let window = DockWindowFacts(isVisible: true)
    private let panel = DockWindowFacts(isVisible: true, isPanel: true, canBecomeMain: false)

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let name = "DockPresenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func absentKeyIsWhileAWindowIsOpen() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        #expect(DockIconMode.current(defaults) == .whileWindowOpen)
        defaults.set("nonsense", forKey: DockIconMode.key)
        #expect(DockIconMode.current(defaults) == .whileWindowOpen)
        for mode in DockIconMode.allCases {
            DockIconMode.set(mode, in: defaults)
            #expect(DockIconMode.current(defaults) == mode)
        }
    }

    @Test func neverStaysAccessoryEvenWithWindows() {
        #expect(DockIconMode.never.policy(windows: [window]) == .accessory)
        #expect(DockIconMode.never.policy(windows: []) == .accessory)
    }

    @Test func alwaysIsRegularEvenWithNoWindows() {
        #expect(DockIconMode.always.policy(windows: []) == .regular)
        #expect(DockIconMode.always.policy(windows: [window]) == .regular)
    }

    @Test func whileOpenFollowsRealWindows() {
        let mode = DockIconMode.whileWindowOpen
        #expect(mode.policy(windows: []) == .accessory)
        #expect(mode.policy(windows: [window]) == .regular)
        #expect(mode.policy(windows: [DockWindowFacts(isVisible: false)]) == .accessory)
        #expect(mode.policy(windows: [DockWindowFacts(isVisible: false, isMiniaturized: true)]) == .regular)
        #expect(mode.policy(windows: [DockWindowFacts(isVisible: true, isClosing: true)]) == .accessory)
        #expect(mode.policy(windows: [DockWindowFacts(isVisible: true, isClosing: true), window]) == .regular)
    }

    @Test func panelsNeverCount() {
        #expect(DockIconMode.whileWindowOpen.policy(windows: [panel]) == .accessory)
        #expect(DockIconMode.whileWindowOpen.policy(windows: [panel, DockWindowFacts(isVisible: true, canBecomeMain: false)]) == .accessory)
        #expect(DockIconMode.whileWindowOpen.policy(windows: [panel, window]) == .regular)
    }

    @Test func realPanelIsRecognized() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        #expect(DockWindowFacts(panel).isPanel)
        #expect(!DockWindowFacts(panel).countsForDock)
    }

    @Test func refreshAppliesOnlyOnChange() {
        var mode = DockIconMode.whileWindowOpen
        var shown: [DockWindowFacts] = []
        var applied: [NSApplication.ActivationPolicy] = []
        let presence = DockPresence(mode: { mode }, windows: { _ in shown }, apply: { applied.append($0) }, notifications: NotificationCenter())
        presence.refresh()
        #expect(applied.isEmpty)
        shown = [window]
        presence.refresh()
        presence.refresh()
        #expect(applied == [.regular])
        shown = []
        presence.refresh()
        #expect(applied == [.regular, .accessory])
        mode = .always
        presence.refresh()
        #expect(applied == [.regular, .accessory, .regular])
        mode = .never
        presence.refresh()
        #expect(presence.policy == .accessory)
    }

    @Test func startAppliesTheSavedModeImmediately() {
        var applied: [NSApplication.ActivationPolicy] = []
        let presence = DockPresence(mode: { .always }, windows: { _ in [] }, apply: { applied.append($0) }, notifications: NotificationCenter())
        presence.start()
        presence.start()
        #expect(applied == [.regular])
    }

    @Test func settingTheModeSavesItAndNotifies() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        var seen: [DockIconMode] = []
        let model = SettingsModel(defaults: defaults, onDockIconModeChanged: { seen.append($0) })
        #expect(model.dockIconMode == .whileWindowOpen)
        model.setDockIconMode(.always)
        #expect(model.dockIconMode == .always)
        #expect(DockIconMode.current(defaults) == .always)
        #expect(seen == [.always])
        defaults.set(DockIconMode.never.rawValue, forKey: DockIconMode.key)
        model.refresh()
        #expect(model.dockIconMode == .never)
    }
}
