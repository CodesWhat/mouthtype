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

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: SettingsTheme.sidebarWidth)
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
        .sheet(isPresented: $model.transcribeOpen) {
            TranscribeFileSheet(model: model, actions: actions)
        }
        .onChange(of: model.page) { _, page in
            // The stats are watched only on their own page.
            if page == .stats { model.stats.activate() } else { model.stats.deactivate() }
            model.syncWords()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in keyboardNavigation = fullKeyboardAccess() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in model.refresh() }
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
            DesignNavRow(title: "Settings", icon: .pixel(.settings), selected: model.settingsOpen) { model.openSettings() }
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
        DesignNavRow(title: page.title, icon: .pixel(page.icon), selected: model.page == page) { model.select(page) }
            .accessibilityIdentifier("settings-page-" + page.rawValue)
            .focused($sidebarFocus, equals: page)
    }

    private func moveSidebar(by offset: Int) -> KeyPress.Result {
        let target = SettingsPage.arrowTarget(focused: sidebarFocus, selected: model.page, offset: offset)
        if model.select(target), sidebarFocus != nil { sidebarFocus = target }
        return .handled
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
