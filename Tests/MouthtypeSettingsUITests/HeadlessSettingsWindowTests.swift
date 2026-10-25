import AppKit
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct HeadlessSettingsWindowTests {
    private func makeWindow(refresh: @escaping () -> Void = {}) throws -> (SettingsWindow, UserDefaults, () -> Void) {
        _ = NSApplication.shared
        let name = "HeadlessSettingsWindow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let model = SettingsModel(defaults: defaults)
        model.page = .style
        let controller = SettingsWindow(
            model: model, actions: SettingsActions(refreshDiagnostics: refresh),
            reduceTransparency: { true }, fullKeyboardAccess: { true }, favicons: SettingsRender.favicons)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (controller, defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let (controller, _, cleanup) = try makeWindow()
        defer { cleanup() }
        let window = try #require(controller.window)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
        #expect(!window.isVisible)
    }

    @Test func pageChangesLeaveTheTextFieldEditorAndSelectionAlone() throws {
        let (controller, _, cleanup) = try makeWindow()
        defer { controller.close(); cleanup() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let field = NSTextField(string: "slack.com")
        field.frame = NSRect(x: 300, y: 80, width: 200, height: 24)
        content.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.selectedRange = NSRange(location: 3, length: 4)
        #expect(SettingsView.sidebarRingPage(in: window) == nil)
        #expect(!SettingsView.clearSidebarRing(in: window))
        #expect(!SettingsView.clearStaleSidebarRing(in: window, selected: .home))
        #expect(!SettingsView.moveSidebarRing(in: window, to: .home))
        controller.clearSidebarFocus()
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange == NSRange(location: 3, length: 4))
        #expect(!window.isVisible)
    }

    @Test func becomingKeyRefreshesSettingsWithoutOpeningAWindow() throws {
        var refreshes = 0
        let (controller, defaults, cleanup) = try makeWindow(refresh: { refreshes += 1 })
        defer { controller.close(); cleanup() }
        let window = try #require(controller.window)
        DictationLanguageSetting.set(.explicit(.german), in: defaults)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(refreshes == 1)
        #expect(controller.model.dictationLanguage == .explicit(.german))
        #expect(controller.isObservingTransparency)
        #expect(!window.isVisible)
    }

    @Test func keyboardSelectionDoesNotCountAsAMouseClick() throws {
        _ = NSApplication.shared
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!SettingsView.isMouseEvent(nil))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(SettingsView.isMouseEvent(event) == (type != .rightMouseDown))
        }
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(!SettingsView.isMouseEvent(key))
    }
}
