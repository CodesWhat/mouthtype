import AppKit
import SwiftUI
import MouthtypeCore

/// The Mouthtype window content: a frosted 212 pt sidebar (Home, Stats, Dictionary, Transforms, Style, Appearance, and a Settings row
/// that opens the modal) beside the page. `solid` swaps the glass sidebar for an opaque fill (Reduce Transparency, and offscreen
/// renders where glass cannot draw). Pages live in `SettingsPageHosts.swift`; the modal in `SettingsModalView.swift`.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    var actions = SettingsActions()
    var solid = true
    /// Reads the system Keyboard navigation setting. Injectable so tests can force either path.
    var fullKeyboardAccess: @MainActor () -> Bool = SettingsView.systemFullKeyboardAccess
    @State private var keyboardNavigation: Bool?
    @State var previewWidth: CGFloat = 0
    @FocusState private var sidebarFocus: SettingsPage?
    @State private var seededSidebarFocus = false
    @State private var arrowMovedPage = false

    var body: some View {
        HStack(spacing: 0) {
            // The window can open already on the selected page (URL route), so no onChange fires; start focus on that row, not the first.
            sidebar.frame(width: SettingsTheme.sidebarWidth)
                .defaultFocus($sidebarFocus, model.page)
            pageContent.frame(maxWidth: .infinity, maxHeight: .infinity).background(DesignPalette.bg)
                .focusSection()
        }
        .font(DesignFont.sans(DesignFont.body))
        .foregroundStyle(DesignPalette.ink)
        .tint(SettingsTheme.control)
        .ignoresSafeArea()
        .frame(minWidth: SettingsTheme.minimumSize.width, minHeight: SettingsTheme.minimumSize.height)
        .sheet(isPresented: $model.settingsOpen) {
            SettingsModalView(model: model, actions: actions, fullKeyboardAccess: fullKeyboardAccess)
        }
        .onChange(of: model.page) { _, page in
            // The stats are watched only on their own page.
            if page == .stats { model.stats.activate() } else { model.stats.deactivate() }
            model.syncWords()
            // A page change from outside the sidebar (URL route, menu) shows no ring: SettingsWindow.present clears sidebar focus.
            // Arrows and clicks move sidebarFocus themselves, so nothing here may pull focus onto a row.
            // A ring is never left on a row other than the selected one: arrows already moved focus with the selection, anything else drops it.
            if arrowMovedPage {
                arrowMovedPage = false
                // The ring is AppKit's first responder and sidebarFocus can be nil while it is on a row, so move both.
                let ringMoved = SettingsView.settingsWindow.map { SettingsView.moveSidebarRing(in: $0, to: page) } ?? false
                if ringMoved || sidebarFocus != nil, sidebarFocus != page { sidebarFocus = page }
            } else {
                if sidebarFocus != page { sidebarFocus = nil }
                if let window = SettingsView.settingsWindow { SettingsView.clearStaleSidebarRing(in: window, selected: page) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            keyboardNavigation = fullKeyboardAccess()
            // AppKit hands the first row focus when the window first becomes key, after any default focus; move it to the selected page.
            // Only the first time, so a row the user Tabbed to isn't pulled back on every return to the window.
            guard !seededSidebarFocus else { return }
            seededSidebarFocus = true
            DispatchQueue.main.async { if let follow = SettingsPage.focusFollowing(focused: sidebarFocus, selected: model.page) { sidebarFocus = follow } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in model.scheduleRefresh() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let mark = SidebarMark.image {
                    Image(nsImage: mark).resizable().interpolation(.high).frame(width: SidebarMark.size, height: SidebarMark.size)
                        .accessibilityHidden(true)
                }
                Text("mouthtype").font(DesignFont.serif(24)).foregroundStyle(DesignPalette.ink)
            }.padding(.horizontal, 8).padding(.top, 52).padding(.bottom, 20)
            // Arrows bubble up from the focused row (Full Keyboard Access on) and move both selection and focus. With it off,
            // plain buttons never take focus, so the list itself is the focus target and arrows step from the selection.
            // With it on the list stays out of the loop, so Tab walks on into the page instead of cycling in the sidebar.
            // The flag is re-read each time the window becomes key, so toggling Keyboard navigation applies on the next focus.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in sidebarPageRow(page) }
            }
            .modifier(SidebarListFocus(focusable: SettingsView.sidebarListFocusable(fullKeyboardAccess: keyboardNavigation ?? fullKeyboardAccess())))
            .onKeyPress(.upArrow) { moveSidebar(by: -1) }
            .onKeyPress(.downArrow) { moveSidebar(by: 1) }
            Spacer(minLength: 12)
            DesignNavRow(title: "Settings", symbol: "gearshape", selected: model.settingsOpen) { model.openSettings() }
                .accessibilityIdentifier("settings-open")
            Text(AppInfo.version.first?.isNumber == true ? "v\(AppInfo.version)" : AppInfo.version).font(DesignFont.mono(DesignFont.eyebrow)).tracking(1).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 14)
        }.padding(.horizontal, 12).padding(.bottom, 16).frame(maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .background { DesignSidebarBackground(solid: solid) }
            .overlay(alignment: .trailing) { Rectangle().fill(DesignPalette.hair2).frame(width: 1) }
    }

    private func sidebarPageRow(_ page: SettingsPage) -> some View {
        DesignNavRow(title: page.title, symbol: page.symbol, selected: model.page == page) {
            model.select(page)
            // A mouse click selects without a keyboard ring; Space or Return on a focused row keeps it.
            if SettingsView.isMouseEvent(NSApp.currentEvent) {
                sidebarFocus = nil
                if let window = SettingsView.settingsWindow { SettingsView.clearSidebarRing(in: window) }
            }
        }
            .accessibilityIdentifier("settings-page-" + page.rawValue)
            .focused($sidebarFocus, equals: page)
    }

    private func moveSidebar(by offset: Int) -> KeyPress.Result {
        let target = SettingsPage.arrowTarget(focused: sidebarFocus, selected: model.page, offset: offset)
        // The page-change handler moves the ring with this selection instead of dropping it as a change from outside.
        arrowMovedPage = true
        if model.select(target) {
            if sidebarFocus != nil { sidebarFocus = target }
        } else { arrowMovedPage = false }
        return .handled
    }

    /// The page rows' key view proxies, top to bottom. Empty when the rows are not Tab stops (Keyboard navigation off).
    static func sidebarRowProxies(in window: NSWindow) -> [NSView] {
        var proxies: [NSView] = []
        func collect(_ view: NSView) {
            if String(describing: type(of: view)) == "KeyViewProxy", view.convert(view.bounds, to: nil).minX < SettingsTheme.sidebarWidth { proxies.append(view) }
            view.subviews.forEach(collect)
        }
        if let content = window.contentView { collect(content) }
        guard let rowHeight = proxies.map({ $0.bounds.height }).min() else { return [] }
        let rows = proxies.filter { $0.bounds.height < rowHeight * 2 }
            .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
        return Array(rows.prefix(SettingsPage.allCases.count))
    }

    /// The Settings window: the key window when it is one, else the open Settings window (the window is not always key during a link open).
    @MainActor static var settingsWindow: NSWindow? {
        if let key = NSApp.keyWindow as? SettingsNSWindow { return key }
        let open = NSApp.windows.filter { $0 is SettingsNSWindow && $0.isVisible }
        return open.first { w in sidebarRowProxies(in: w).contains { $0 === w.firstResponder } } ?? open.first
    }

    static func isMouseEvent(_ event: NSEvent?) -> Bool {
        guard let type = event?.type else { return false }
        return type == .leftMouseDown || type == .leftMouseUp
    }

    /// Drops first responder when a sidebar row holds it. Anything else holding focus is left alone.
    @discardableResult @MainActor static func clearSidebarRing(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView, sidebarRowProxies(in: window).contains(where: { $0 === responder }) else { return false }
        return window.makeFirstResponder(nil)
    }

    /// Drops the ring when a sidebar row other than `selected`'s holds it.
    @discardableResult @MainActor static func clearStaleSidebarRing(in window: NSWindow, selected: SettingsPage) -> Bool {
        let rows = sidebarRowProxies(in: window)
        guard let responder = window.firstResponder as? NSView, let held = rows.firstIndex(where: { $0 === responder }),
              SettingsPage.allCases.firstIndex(of: selected) != held else { return false }
        return window.makeFirstResponder(nil)
    }

    /// Moves the focus ring to `page`'s row when a sidebar row currently has it. Anything else holding focus (a text field's editor, a page
    /// control) is left alone. Returns whether the ring moved.
    @discardableResult @MainActor static func moveSidebarRing(in window: NSWindow, to page: SettingsPage) -> Bool {
        guard let responder = window.firstResponder as? NSView, !(responder is NSText) else { return false }
        let rows = sidebarRowProxies(in: window)
        guard rows.contains(where: { $0 === responder }), let index = SettingsPage.allCases.firstIndex(of: page), index < rows.count else { return false }
        return rows[index] === responder || window.makeFirstResponder(rows[index])
    }

    /// With Full Keyboard Access the rows are Tab stops themselves, so the list must not also be one or Tab cycles in the sidebar.
    static func sidebarListFocusable(fullKeyboardAccess: Bool) -> Bool { !fullKeyboardAccess }

    @MainActor static func systemFullKeyboardAccess() -> Bool { NSApp?.isFullKeyboardAccessEnabled ?? false }
}

/// Makes the sidebar list a focus target only when `focusable`, with its focus ring suppressed (arrows drive selection there). When not
/// focusable the rows are the focus targets and keep their system focus effect, the only cue for where focus is. Passing `false` to `.focusable(_:)` is not the same as leaving it
/// off: it disables focus for every descendant, so under Full Keyboard Access the rows lost their own Tab stops.
struct SidebarListFocus: ViewModifier {
    let focusable: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if focusable { content.focusable().focusEffectDisabled() } else { content }
    }
}

/// The sidebar mark is the app's own icon as the system draws it (squircle mask, Dark and Tinted styles). Builds without
/// a bundle icon, such as tests and previews, fall back to the exported art clipped to the same shape.
@MainActor
enum SidebarMark {
    static let size: CGFloat = 36

    static var image: NSImage? {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil {
            return NSApp.applicationIconImage
        }
        guard let url = Bundle.module.url(forResource: "mouthtype", withExtension: "png", subdirectory: "Settings"),
              let art = NSImage(contentsOf: url) else { return nil }
        return clipped(art)
    }

    private static func clipped(_ art: NSImage) -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
            art.draw(in: rect)
            return true
        }
    }
}
