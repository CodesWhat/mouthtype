import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// Builds the real Settings window offscreen and checks the keyboard path from the sidebar into each page.
@MainActor @Suite struct SettingsKeyboardAccessTests {
    private func makeWindow(page: SettingsPage) -> SettingsWindow {
        let name = "SettingsKeyboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = SettingsModel(defaults: defaults)
        model.page = page
        let controller = SettingsWindow(model: model, reduceTransparency: { true })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func controls(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view.acceptsFirstResponder, !view.isHidden { found.append(view) }
        for sub in view.subviews { found += controls(in: sub) }
        return found
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let controller = makeWindow(page: .general)
        let window = try #require(controller.window)
        #expect(window is SettingsNSWindow)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
    }

    @Test func everyPageExposesFocusableControlsInsideTheHostedContent() throws {
        for page in SettingsPage.allCases where page != .diagnostics {
            let controller = makeWindow(page: page)
            let content = try #require(controller.window?.contentView)
            #expect(!controls(in: content).isEmpty, "\(page) has no first-responder-capable controls")
        }
    }

    @Test func pageControlsJoinTheKeyViewLoopOnlyWhenKeyboardNavigationIsOn() throws {
        let controller = makeWindow(page: .general)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let page = controls(in: content)
        #expect(!page.isEmpty)
        // With Full Keyboard Access on, AppKit lets these controls become key views. Without it they stay out of the
        // loop, which is the standard macOS behaviour we keep.
        for control in page { #expect(control.canBecomeKeyView == NSApp.isFullKeyboardAccessEnabled) }
        window.recalculateKeyViewLoop()
        if NSApp.isFullKeyboardAccessEnabled {
            var visited = Set<ObjectIdentifier>()
            var view = content.nextValidKeyView
            while let current = view, visited.insert(ObjectIdentifier(current)).inserted { view = current.nextValidKeyView }
            #expect(page.allSatisfy { visited.contains(ObjectIdentifier($0)) })
        }
    }

    @Test func sidebarPagesStepWithArrowsAndStopAtTheEnds() {
        #expect(SettingsPage.general.moved(by: 1) == .writing)
        #expect(SettingsPage.diagnostics.moved(by: 1) == .diagnostics)
        #expect(SettingsPage.general.moved(by: -1) == .general)
    }
}
