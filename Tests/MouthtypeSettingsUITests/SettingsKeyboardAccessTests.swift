import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// Builds the real Settings window offscreen and checks the keyboard path from the sidebar into each page.
@MainActor @Suite struct SettingsKeyboardAccessTests {
    private func makeWindow(page: SettingsPage, fullKeyboardAccess: Bool = false) -> SettingsWindow {
        let name = "SettingsKeyboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = SettingsModel(defaults: defaults)
        model.page = page
        let controller = SettingsWindow(model: model, reduceTransparency: { true }, fullKeyboardAccess: { fullKeyboardAccess })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let controller = makeWindow(page: .general)
        let window = try #require(controller.window)
        #expect(window is SettingsNSWindow)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
    }

    /// The reported bug: with Full Keyboard Access on the rows are Tab stops, so the list container must not be one too,
    /// or Tab cycles inside the sidebar. The old code kept it focusable unconditionally. SwiftUI focus isn't visible to
    /// AppKit offscreen (the hosting view exposes no key views or accessibility children), so the policy is tested directly.
    @Test func sidebarListLeavesTheTabLoopUnderFullKeyboardAccess() {
        #expect(!SettingsView.sidebarListFocusable(fullKeyboardAccess: true))
        #expect(SettingsView.sidebarListFocusable(fullKeyboardAccess: false))
    }

    @Test func windowBuildsWithTheKeyboardFlagForcedEitherWay() throws {
        for flag in [true, false] {
            let controller = makeWindow(page: .general, fullKeyboardAccess: flag)
            #expect(controller.window?.contentView != nil)
        }
    }

    /// Page controls are only keyboard-reachable while they're native Button, Picker or Toggle. A tap or drag gesture on a
    /// plain view is invisible to Tab and Space, so none may appear in the Settings sources.
    @Test func settingsPagesUseNoMouseOnlyGestureControls() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MouthtypeMac/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in ["onTapGesture", ".gesture(", "TapGesture", "onLongPressGesture"] {
                #expect(!text.contains(pattern), "\(file.lastPathComponent) uses \(pattern)")
            }
        }
    }
    @Test func arrowsStepFromTheFocusedRowOtherwiseFromTheSelection() {
        #expect(SettingsPage.arrowTarget(focused: .appearance, selected: .general, offset: -1) == .writing)
        #expect(SettingsPage.arrowTarget(focused: nil, selected: .writing, offset: 1) == .appearance)
        #expect(SettingsPage.arrowTarget(focused: nil, selected: .diagnostics, offset: 1) == .diagnostics)
    }

    @Test func sidebarPagesStepWithArrowsAndStopAtTheEnds() {
        #expect(SettingsPage.general.moved(by: 1) == .writing)
        #expect(SettingsPage.diagnostics.moved(by: 1) == .diagnostics)
        #expect(SettingsPage.general.moved(by: -1) == .general)
    }
}
