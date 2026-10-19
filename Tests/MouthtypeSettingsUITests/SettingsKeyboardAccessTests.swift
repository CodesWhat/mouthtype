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

    /// The reported bug: Tab from the sidebar has to reach the page. AppKit only puts buttons in the key view loop under
    /// Full Keyboard Access, so this is gated on it and does nothing on a machine with it off. The real Tab pass on a
    /// built app remains a manual check.
    @Test func tabFromTheSidebarReachesThePageInsteadOfCyclingInside() throws {
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let controller = makeWindow(page: .general)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        window.recalculateKeyViewLoop()
        let all = controls(in: content)
        let sidebarEdge = SettingsTheme.sidebarWidth
        func inSidebar(_ view: NSView) -> Bool { view.convert(view.bounds, to: nil).midX < sidebarEdge }
        let start = try #require(all.first(where: inSidebar))
        var view: NSView? = start
        var reachedPage = false
        var visited = Set<ObjectIdentifier>()
        while let current = view?.nextValidKeyView, visited.insert(ObjectIdentifier(current)).inserted {
            if !inSidebar(current) { reachedPage = true; break }
            view = current
        }
        #expect(reachedPage, "Tab never left the sidebar")
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
