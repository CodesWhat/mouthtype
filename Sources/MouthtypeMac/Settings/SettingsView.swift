import AppKit
import SwiftUI
import MouthtypeCore

/// The Settings window content: a 210 pt sidebar and a grouped-form page under a 46 pt header bar. `solid` swaps the
/// glass sidebar for an opaque fill (Reduce Transparency, and offscreen renders where glass cannot draw).
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
            VStack(spacing: 0) {
                header
                switch model.page {
                case .savedSpellings: SavedSpellingsPage(model: model)
                case .phrases: PhrasesPage(model: model)
                case .transcribeFile: FileTranscriptionHostPage(model: model, actions: actions)
                default: SettingsForm {
                    switch model.page {
                    case .savedSpellings, .phrases, .transcribeFile: EmptyView()
                    case .home: HomePage(model: model.home)
                    case .stats: StatsHostPage(model: model.stats)
                    case .records: RecordsHostPage(model: model.stats)
                    case .general: general
                    case .writing: writing
                    case .appearance: appearance
                    case .diagnostics:
                        if let diagnostics = actions.diagnostics { SettingsDiagnosticsView(state: diagnostics, model: model, actions: actions) }
                        else { SettingsGroup(eyebrow: "DIAGNOSTICS") { SettingsNote(text: "Diagnostic status is unavailable.") } }
                    }
                }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                .focusSection()
        }
        .font(SettingsFont.sans(SettingsFont.body))
        .foregroundStyle(.primary)
        .tint(SettingsTheme.control)
        .ignoresSafeArea()
        .frame(minWidth: SettingsTheme.minimumSize.width, minHeight: SettingsTheme.minimumSize.height)
        .onChange(of: model.page) { _, page in
            // The stats are watched only on their own pages. Moving between Stats and Records keeps one observation.
            if page == .stats || page == .records { model.stats.activate() } else { model.stats.deactivate() }
            model.syncWords()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in keyboardNavigation = fullKeyboardAccess() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in model.refresh() }
    }

    private var header: some View {
        let title = Text(model.page.headline).font(SettingsFont.serif(SettingsFont.title))
            .accessibilityAddTraits(.isHeader)
        let summary = Text(model.page.summary).font(SettingsFont.sans(SettingsFont.headerDescription)).foregroundStyle(.secondary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14) { title.fixedSize(); summary.fixedSize() }
            VStack(alignment: .leading, spacing: 2) { title; summary.fixedSize(horizontal: false, vertical: true) }.padding(.vertical, 6)
        }.padding(.horizontal, 24).padding(.top, 8)
            .frame(maxWidth: .infinity, minHeight: SettingsTheme.headerHeight, alignment: .leading)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let mark = SidebarMark.image {
                    Image(nsImage: mark).resizable().interpolation(.high).frame(width: SidebarMark.size, height: SidebarMark.size)
                        .accessibilityHidden(true)
                }
                Text("mouthtype").font(SettingsFont.serif(SettingsFont.wordmark))
            }.padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 22)
            // Arrows bubble up from the focused row (Full Keyboard Access on) and move both selection and focus. With it off,
            // plain buttons never take focus, so the list itself is the focus target and arrows step from the selection.
            // With it on the list stays out of the loop, so Tab walks on into the page instead of cycling in the sidebar.
            // The flag is re-read each time the window becomes key, so toggling Keyboard navigation applies on the next focus.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarPageRow(.home)
                    sidebarPageRow(.stats)
                    sidebarPageRow(.records)
                    sidebarPageRow(.transcribeFile)
                }
                Text("YOUR WORDS").font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.wordsPages) { page in sidebarPageRow(page) }
                }
                Text("SETTINGS").font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.settingsPages) { page in sidebarPageRow(page) }
                }
            }
            .modifier(SidebarListFocus(focusable: SettingsView.sidebarListFocusable(fullKeyboardAccess: keyboardNavigation ?? fullKeyboardAccess())))
            .onKeyPress(.upArrow) { moveSidebar(by: -1) }
            .onKeyPress(.downArrow) { moveSidebar(by: 1) }
            Spacer(minLength: 12)
            linkRow(.setUp)
            Text("ON YOUR MAC · \(AppInfo.version)").font(SettingsFont.mono(SettingsFont.footer)).tracking(1).lineSpacing(4)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 18)
        }.padding(.horizontal, 10).frame(maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .background { if solid { Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.04)) } }
            .overlay(alignment: .trailing) { if solid { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) } }
    }

    private func sidebarPageRow(_ page: SettingsPage) -> some View {
        sidebarRow(page.title, icon: page.icon, selected: model.page == page, id: "settings-page-" + page.rawValue) { model.select(page) }
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

    private func linkRow(_ link: SettingsSidebarLink) -> some View {
        sidebarRow(link.title, icon: link.icon, selected: false, id: link.accessibilityID) { actions.perform(link) }
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(SettingsTheme.symbol).frame(width: 18)
                Text(title).font(SettingsFont.sans(SettingsFont.body)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                .background { if selected { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)) } }
        }.buttonStyle(.plain).accessibilityIdentifier(id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Makes the sidebar list a focus target only when `focusable`, with its focus ring suppressed (arrows drive selection there). When not
/// focusable the rows are the focus targets and keep their system focus effect, the only cue for where focus is. Passing `false` to `.focusable(_:)` is not the same as leaving it
/// off: it disables focus for every descendant, so under Full Keyboard Access the rows lost their own Tab stops.
private struct SidebarListFocus: ViewModifier {
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
