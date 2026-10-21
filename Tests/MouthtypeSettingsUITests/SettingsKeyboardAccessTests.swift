import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

/// Builds the real Settings window offscreen and checks the keyboard path from the sidebar into each page.
@MainActor @Suite struct SettingsKeyboardAccessTests {
    private func makeWindow(page: SettingsPage, fullKeyboardAccess: Bool = false, home: HomeLogModel = HomeLogModel()) -> SettingsWindow {
        let name = "SettingsKeyboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = SettingsModel(defaults: defaults, home: home)
        model.page = page
        let controller = SettingsWindow(model: model, reduceTransparency: { true }, fullKeyboardAccess: { fullKeyboardAccess })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let controller = makeWindow(page: .home)
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
            let controller = makeWindow(page: .home, fullKeyboardAccess: flag)
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
    private func keyWindow(page: SettingsPage, fullKeyboardAccess: Bool, home: HomeLogModel = HomeLogModel()) throws -> (SettingsWindow, SettingsNSWindow) {
        _ = NSApplication.shared
        Self.installSystemFullKeyboardAccessOverride
        Self.forcedSystemFullKeyboardAccess = fullKeyboardAccess
        let controller = makeWindow(page: page, fullKeyboardAccess: fullKeyboardAccess, home: home)
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

    /// Appearance is built from the redesign's own controls (style tiles, segmented controls, switch), which are plain buttons and so are
    /// proxies in the loop. Tab must walk the sidebar and then reach all of them: five style tiles, two preview swatches, three sizes at least.
    @Test func tabReachesTheAppearanceStyleTilesAndSegmentsUnderFullKeyboardAccess() throws {
        let (controller, window) = try keyWindow(page: .appearance, fullKeyboardAccess: true)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let stops = try tabOrder(window)
        let sidebar = stops.prefix { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }
        #expect(sidebar.count == SettingsPage.allCases.count + 1)
        let pageStops = stops.dropFirst(sidebar.count).filter { $0.x >= SettingsTheme.sidebarWidth }
        #expect(pageStops.count >= PillSkinKind.allCases.count + PreviewWallpaper.allCases.count + PillSize.allCases.count,
                "Appearance: \(pageStops.count) page Tab stops")
    }


    /// Home's Copy and Recover buttons are plain buttons, so they are proxies in the loop. Tab must walk the sidebar rows (Home included)
    /// and then reach every row button in order, and `previousKeyView` must mirror it so Shift-Tab steps back through the same stops.
    @Test func tabReachesHomeRowButtonsAfterTheSidebarAndShiftTabMirrorsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-home-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        var firstID = ""
        for (index, text) in ["first take", "second take"].enumerated() {
            let id = try store.begin(DictationStart(startedAt: Date().addingTimeInterval(Double(-index) * 60), target: DictationTarget()))
            try store.recordInsertion(id, InsertionRecord(finalText: text))
            if index == 0 { firstID = id }
        }
        let home = HomeLogModel(store: store, canRecover: { true })
        await home.loadText()
        home.attach([RecoverableDictation(id: firstID, startedAt: Date(), audioURL: URL(fileURLWithPath: "/tmp/a.wav"), seconds: 3, isPartial: false)])
        let (controller, window) = try keyWindow(page: .home, fullKeyboardAccess: true, home: home)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let stops = try tabOrder(window)
        let sidebar = stops.prefix { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }
        #expect(sidebar.count == SettingsPage.allCases.count + 1)
        let pageStops = stops.dropFirst(sidebar.count).filter { $0.isProxy && $0.x >= SettingsTheme.sidebarWidth }
        #expect(pageStops.count == 4, "Home: \(pageStops.count) button stops, expected Transcribe a file, Copy, Recover, Copy")
        let chain = try keyViewChain(window)
        for (current, next) in zip(chain, chain.dropFirst()) {
            #expect(next.previousKeyView === current, "previousKeyView of \(type(of: next)) does not mirror nextKeyView")
        }
    }

    /// The Style page is built from buttons, so its tabs, tone cards and rows are proxy stops after the sidebar.
    @Test func tabReachesStyleTabsAndToneCardsAfterTheSidebar() throws {
        let (controller, window) = try keyWindow(page: .style, fullKeyboardAccess: true)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let stops = try tabOrder(window)
        let sidebar = stops.prefix { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }
        #expect(sidebar.count == SettingsPage.allCases.count + 1)
        #expect(stops.dropFirst(sidebar.count).filter { $0.isProxy && $0.x >= SettingsTheme.sidebarWidth }.count >= 8)
    }

    /// With Keyboard navigation off the list is itself the focus target, ahead of the rows, and Tab still continues into the page.
    @Test func tabLoopStillReachesPageControlsWithKeyboardNavigationOff() throws {
        let (controller, window) = try keyWindow(page: .appearance, fullKeyboardAccess: false)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let stops = try tabOrder(window)
        #expect(stops.contains { $0.x >= SettingsTheme.sidebarWidth })
        #expect(stops.filter { $0.isProxy && $0.x < SettingsTheme.sidebarWidth }.count == SettingsPage.allCases.count + 2)
        try expectTabReachesPageControl(window, sidebarStops: SettingsPage.allCases.count + 2, "keyboard navigation off")
    }

    /// Every view `nextKeyView` links from the first proxy, in order, until the loop closes.
    private func keyViewChain(_ window: NSWindow) throws -> [NSView] {
        var proxies: [NSView] = []
        func collect(_ view: NSView) {
            if String(describing: type(of: view)) == "KeyViewProxy" { proxies.append(view) }
            view.subviews.forEach(collect)
        }
        collect(try #require(window.contentView))
        var chain: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        var view = proxies.first { $0.superview === window.contentView }
        while let current = view, seen.insert(ObjectIdentifier(current)).inserted { chain.append(current); view = current.nextKeyView }
        return chain
    }

    /// Hosted offscreen, `canBecomeKeyView` is false for every view in the loop (even the page popups) and `selectNextKeyView` stays put,
    /// because AppKit only treats views as valid key views once the app is active with a key window. So Tab can't be driven for real here.
    /// The strongest check that works is walking the published `nextKeyView` links: from the first sidebar stop, a page control (a view that
    /// accepts first responder, right of the sidebar) must be reached before the sidebar rows repeat, and `previousKeyView` must mirror it.
    private func expectTabReachesPageControl(_ window: NSWindow, sidebarStops: Int, _ label: String) throws {
        let chain = try keyViewChain(window)
        let pageControl = chain.firstIndex { $0.acceptsFirstResponder && $0.convert($0.bounds, to: nil).minX >= SettingsTheme.sidebarWidth }
        let index = try #require(pageControl, "\(label): no page control in the key view chain")
        let before = chain.prefix(index).filter { String(describing: type(of: $0)) == "KeyViewProxy" && $0.convert($0.bounds, to: nil).minX < SettingsTheme.sidebarWidth }
        #expect(before.count == sidebarStops, "\(label): \(before.count) sidebar stops precede the first page control, expected \(sidebarStops)")
        for (current, next) in zip(chain, chain.dropFirst()) {
            #expect(next.previousKeyView === current, "\(label): previousKeyView of \(type(of: next)) does not mirror nextKeyView")
        }
    }

    private final class Stop: NSView {
        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    /// Shift-Tab steps back through the forward Tab order and wraps, because the hosted controls only link forward.
    @Test func shiftTabStepsBackThroughTheForwardTabOrder() {
        let root = NSView()
        let stops = (0..<4).map { _ in Stop() }
        stops.forEach(root.addSubview)
        root.nextKeyView = stops[0]
        for (current, next) in zip(stops, stops.dropFirst()) { current.nextKeyView = next }
        stops[3].nextKeyView = root
        #expect(SettingsKeyLoop.order(in: root).count == 4)
        #expect(SettingsKeyLoop.previous(of: stops[2], in: root) === stops[1])
        #expect(SettingsKeyLoop.previous(of: stops[0], in: root) === stops[3])
        #expect(SettingsKeyLoop.previous(of: NSView(), in: root) == nil)
    }

    /// The page's scroll view and a keyboard stop in it that starts below the fold.
    private func pageScrollAndOffscreenStop(_ window: NSWindow) throws -> (NSScrollView, NSView) {
        var scrolls: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.convert(scroll.bounds, to: nil).minX >= SettingsTheme.sidebarWidth { scrolls.append(scroll) }
            view.subviews.forEach(collect)
        }
        collect(try #require(window.contentView))
        let scroll = try #require(scrolls.max { $0.bounds.height < $1.bounds.height }, "no page scroll view")
        let document = try #require(scroll.documentView)
        let stop = try keyViewChain(window).filter { $0.enclosingScrollView === scroll && $0.acceptsFirstResponder }
            .max { $0.convert($0.bounds, to: document).maxY < $1.convert($1.bounds, to: document).maxY }
        let target = try #require(stop, "no focusable control in the page")
        #expect(target.convert(target.bounds, to: document).maxY > scroll.documentVisibleRect.maxY, "control is not below the fold")
        return (scroll, target)
    }

    /// Tab (and the Shift-Tab path) must bring a control below the fold into view.
    @Test func keyboardFocusScrollsTheControlIntoView() throws {
        let (controller, window) = try keyWindow(page: .style, fullKeyboardAccess: true)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let (scroll, target) = try pageScrollAndOffscreenStop(window)
        let document = try #require(scroll.documentView)
        #expect(window.focusByKeyboard(target))
        scroll.layoutSubtreeIfNeeded()
        let frame = target.convert(target.bounds, to: document)
        #expect(scroll.documentVisibleRect.contains(frame), "frame \(frame) outside visible \(scroll.documentVisibleRect)")
    }

    /// A click (plain makeFirstResponder) must not move the page.
    @Test func nonKeyboardFocusDoesNotScroll() throws {
        let (controller, window) = try keyWindow(page: .style, fullKeyboardAccess: true)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        let (scroll, target) = try pageScrollAndOffscreenStop(window)
        let before = scroll.contentView.bounds.origin
        #expect(window.makeFirstResponder(target))
        #expect(scroll.contentView.bounds.origin == before)
    }

    private func press(_ key: UInt32, keyCode: UInt16, in window: NSWindow) throws {
        let characters = String(UnicodeScalar(key)!)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
        for _ in 0..<3 { while let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(e) } }
    }

    /// The window's initial first responder comes from AppKit's real keyboard UI mode, which the injected flag can't reach: with the machine's
    /// Keyboard navigation on it is the first sidebar row, not the list. Focus the list proxy (the sidebar proxy taller than a single row)
    /// so the test starts from the same place whatever the system setting is. The event pump lets SwiftUI settle the focus change before
    /// the first arrow, otherwise that arrow is spent moving focus.
    private func focusSidebarList(in window: NSWindow) throws {
        let sidebar = try keyViewChain(window).filter {
            String(describing: type(of: $0)) == "KeyViewProxy" && $0.convert($0.bounds, to: nil).minX < SettingsTheme.sidebarWidth
        }
        let rowHeight = try #require(sidebar.map { $0.bounds.height }.min())
        let list = try #require(sidebar.first { $0.bounds.height > rowHeight * 2 }, "no sidebar list proxy in the key view chain")
        #expect(window.makeFirstResponder(list))
        for _ in 0..<3 { while let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(e) } }
    }

    /// With Keyboard navigation off the list is the focus target and the arrow handlers drive selection. Real key events go through the
    /// window, so deleting `onKeyPress` (or the list's focus) leaves the page where it was and fails this.
    @Test func arrowKeysMoveSidebarSelectionWithKeyboardNavigationOff() throws {
        let (controller, window) = try keyWindow(page: .style, fullKeyboardAccess: false)
        defer { window.close(); _ = controller; Self.forcedSystemFullKeyboardAccess = nil }
        try focusSidebarList(in: window)
        try press(UInt32(NSDownArrowFunctionKey), keyCode: 125, in: window)
        #expect(controller.model.page == .appearance)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .style)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .transforms)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .dictionary)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .stats)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .home)
        try press(UInt32(NSUpArrowFunctionKey), keyCode: 126, in: window)
        #expect(controller.model.page == .home)
    }

    @Test func arrowsStepFromTheFocusedRowOtherwiseFromTheSelection() {
        #expect(SettingsPage.arrowTarget(focused: .appearance, selected: .home, offset: -1) == .style)
        #expect(SettingsPage.arrowTarget(focused: nil, selected: .style, offset: 1) == .appearance)
        #expect(SettingsPage.arrowTarget(focused: nil, selected: .appearance, offset: 1) == .appearance)
    }

    @Test func sidebarFocusFollowsTheSelectionOnlyWhenARowHasFocus() {
        #expect(SettingsPage.focusFollowing(focused: .home, selected: .stats) == .stats)
        #expect(SettingsPage.focusFollowing(focused: .stats, selected: .stats) == .stats)
        #expect(SettingsPage.focusFollowing(focused: nil, selected: .stats) == nil)
        // First key on a window opened straight onto Stats: AppKit focuses Home, the ring has to land on the selected row.
        #expect(SettingsPage.focusFollowing(focused: .home, selected: .stats) != .home)
    }

    @Test func sidebarPagesStepWithArrowsAndStopAtTheEnds() {
        #expect(SettingsPage.style.moved(by: 1) == .appearance)
        #expect(SettingsPage.appearance.moved(by: 1) == .appearance)
        #expect(SettingsPage.style.moved(by: -1) == .transforms)
        #expect(SettingsPage.stats.moved(by: -1) == .home)
        #expect(SettingsPage.home.moved(by: -1) == .home)
    }
}
