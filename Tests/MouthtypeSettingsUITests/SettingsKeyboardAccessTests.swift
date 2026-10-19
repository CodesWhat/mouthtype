import AppKit
import ObjectiveC
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
    /// or Tab cycles inside the sidebar. This pins the policy only. The hosted loop tests below cover how it is applied.
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
    // MARK: Hosted key view loop

    /// Orders the real window front and pumps AppKit's event queue. SwiftUI builds its key view proxies once the window is on screen; whether macOS
    /// lets a test process become the active app depends on the desktop session, so the window is not required to be key.
    private func keyWindow(page: SettingsPage, fullKeyboardAccess: Bool) throws -> (SettingsWindow, SettingsNSWindow) {
        _ = NSApplication.shared
        Self.installSystemFullKeyboardAccessOverride
        Self.forcedSystemFullKeyboardAccess = fullKeyboardAccess
        let controller = makeWindow(page: page, fullKeyboardAccess: fullKeyboardAccess)
        let window = try #require(controller.window as? SettingsNSWindow)
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        for _ in 0..<5 {
            while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            if window.isKeyWindow { break }
            window.makeKeyAndOrderFront(nil)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// `NSApp.isFullKeyboardAccessEnabled` can't be flipped from a test, and SwiftUI consults it when deciding which controls are Tab stops.
    /// The getter is replaced once with one that reports `forcedSystemFullKeyboardAccess` (falling back to the real value).
    private nonisolated(unsafe) static var forcedSystemFullKeyboardAccess: Bool?
    private static let installSystemFullKeyboardAccessOverride: Void = {
        let selector = NSSelectorFromString("isFullKeyboardAccessEnabled")
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (AnyObject) -> Bool = { app in forcedSystemFullKeyboardAccess ?? original(app, selector) }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }()

    private struct LoopStop { let isProxy: Bool; let x: CGFloat }

    /// The key view loop SwiftUI publishes through `nextKeyView`, in Tab order, starting at the first proxy in the hosting view.
    /// `nextValidKeyView` is nil for every hosted view offscreen (even popup to popup), so the loop is read structurally.
    private func tabOrder(_ window: NSWindow) throws -> [LoopStop] {
        var proxies: [NSView] = []
        func collect(_ view: NSView) {
            if String(describing: type(of: view)) == "KeyViewProxy" { proxies.append(view) }
            view.subviews.forEach(collect)
        }
        collect(try #require(window.contentView))
        var stops: [LoopStop] = []
        var seen = Set<ObjectIdentifier>()
        var view = proxies.first { $0.superview === window.contentView }
        while let current = view, seen.insert(ObjectIdentifier(current)).inserted {
            let x = current.convert(current.bounds, to: nil).minX
            if String(describing: type(of: current)) == "KeyViewProxy" { stops.append(LoopStop(isProxy: true, x: x)) }
            else if current is NSPopUpButton || current is NSSwitch || (current as? NSTextField)?.isEditable == true { stops.append(LoopStop(isProxy: false, x: x)) }
            view = current.nextKeyView
        }
        return stops
    }

    /// Reported bug: with Keyboard navigation on, Tab never left the sidebar. Passing `.focusable(false)` on the list disabled focus for
    /// the page rows under it, so the sidebar's four page rows dropped out of the key view loop. Every sidebar row (four pages, three
    /// links) must be a Tab stop, followed directly by the page's controls.
    @Test func tabWalksSidebarRowsThenIntoPageControlsUnderFullKeyboardAccess() throws {
        for page in [SettingsPage.general, .writing, .appearance] {
            let (controller, window) = try keyWindow(page: page, fullKeyboardAccess: true)
            defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
            let stops = try tabOrder(window)
            let sidebar = stops.prefix { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }
            #expect(sidebar.count == SettingsPage.allCases.count + 3, "\(page): \(sidebar.count) sidebar Tab stops")
            #expect(stops.dropFirst(sidebar.count).contains { !$0.isProxy && $0.x >= SettingsTheme.sidebarWidth }, "\(page): Tab never reaches a page control")
        }
    }

    /// With Keyboard navigation off the list is itself the focus target, ahead of the rows, and Tab still continues into the page.
    @Test func tabLoopStillReachesPageControlsWithKeyboardNavigationOff() throws {
        let (controller, window) = try keyWindow(page: .general, fullKeyboardAccess: false)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let stops = try tabOrder(window)
        #expect(stops.contains { !$0.isProxy && $0.x >= SettingsTheme.sidebarWidth })
        #expect(stops.filter { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }.count == SettingsPage.allCases.count + 4)
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
