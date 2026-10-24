import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SettingsKeyLoopTests {
    @Test func returningToAHostedDomainByKeyboardSelectsItsText() async throws {
        _ = NSApplication.shared
        let window = SettingsNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView:
                TextField("Domain, e.g. slack.com", text: .constant("slack.com"))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("style-website-domain")
                .padding().frame(width: 480, height: 200))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(host).first)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        #expect(window.makeFirstResponder(nil))
        #expect(window.focusByKeyboard(field))
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 9))
        #expect(!window.isVisible)
    }

    private final class Stop: NSView {
        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    /// The reported bug: with Full Keyboard Access on the rows are Tab stops, so the list container must not be one too,
    /// or Tab cycles inside the sidebar. This pins the policy only. The hosted loop tests below cover how it is applied.
    @Test func sidebarListLeavesTheTabLoopUnderFullKeyboardAccess() {
        #expect(!SettingsView.sidebarListFocusable(fullKeyboardAccess: true))
        #expect(SettingsView.sidebarListFocusable(fullKeyboardAccess: false))
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
