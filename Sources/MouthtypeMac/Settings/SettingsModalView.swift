import AppKit
import SwiftUI
import MouthtypeCore

/// The Settings modal: a 760x540 sheet on the Mouthtype window with a mini-nav (General, Mac, Health, and Advanced while its footer
/// switch is on). Esc and the close button dismiss it. Nested editors (the shortcut recorder, Add application) open as another
/// sheet on top of this one, see `SettingsWindow.topmostWindow`.
struct SettingsModalView: View {
    static let size = CGSize(width: 760, height: 540)
    static let navWidth: CGFloat = 200

    @Bindable var model: SettingsModel
    var actions = SettingsActions()
    var fullKeyboardAccess: @MainActor () -> Bool = SettingsView.systemFullKeyboardAccess
    @State private var keyboardNavigation: Bool?
    @FocusState private var navFocus: SettingsModalPage?

    var body: some View {
        HStack(spacing: 0) {
            nav.frame(width: Self.navWidth)
            ZStack(alignment: .topTrailing) {
                pageBody
                DesignCloseButton(label: "Close settings") { model.closeSettings() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-modal-close")
                    .padding(.top, 14).padding(.trailing, 14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DesignPalette.bg).focusSection()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DesignPalette.bg)
        .font(DesignFont.sans(DesignFont.body))
        .foregroundStyle(DesignPalette.ink)
        .tint(SettingsTheme.control)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in keyboardNavigation = fullKeyboardAccess() }
    }

    // MARK: Nav

    private var pages: [SettingsModalPage] { SettingsModalPage.visible(advanced: model.advancedOptions) }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").designEyebrow().foregroundStyle(DesignPalette.ink2).padding(.horizontal, 10).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pages) { page in
                    DesignNavRow(title: page.title, symbol: page.symbol, selected: model.modalPage == page, height: 34) { model.selectModal(page) }
                        .accessibilityIdentifier("settings-modal-" + page.rawValue)
                        .focused($navFocus, equals: page)
                }
            }
            .modifier(SidebarListFocus(focusable: SettingsView.sidebarListFocusable(fullKeyboardAccess: keyboardNavigation ?? fullKeyboardAccess())))
            .onKeyPress(.upArrow) { moveNav(by: -1) }
            .onKeyPress(.downArrow) { moveNav(by: 1) }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("Advanced options").font(DesignFont.sans(DesignFont.detail, .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Toggle("Advanced options", isOn: Binding(get: { model.advancedOptions }, set: model.setAdvancedOptions))
                    .labelsHidden().toggleStyle(.designSwitchCompact).accessibilityIdentifier("settings-advanced-options")
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            .overlay(alignment: .top) { DesignHairline() }
            Text("MOUTHTYPE \(AppInfo.version)").font(DesignFont.mono(DesignFont.eyebrow)).tracking(1).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
        }
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background { DesignSidebarBackground(solid: true) }
        .overlay(alignment: .trailing) { Rectangle().fill(DesignPalette.hair2).frame(width: 1) }
        .focusSection()
    }

    private func moveNav(by offset: Int) -> KeyPress.Result {
        let list = pages
        let current = navFocus ?? model.modalPage
        let index = list.firstIndex(of: current) ?? 0
        let target = list[min(max(index + offset, 0), list.count - 1)]
        model.selectModal(target)
        if navFocus != nil { navFocus = target }
        return .handled
    }

    // MARK: Page

    private var pageBody: some View {
        let page = model.modalPage
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DesignPageHeader(title: page.headline, summary: page.summary, titleSize: 24).padding(.trailing, 40)
                VStack(alignment: .leading, spacing: 14) { pageContent(page) }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.environment(\.settingsFormScrolls, false)
    }

    private var host: SettingsView { SettingsView(model: model, actions: actions) }

    @ViewBuilder private func pageContent(_ page: SettingsModalPage) -> some View {
        switch page {
        case .general:
            host.generalInput
            host.generalRecording
        case .mac:
            host.macPage
        case .health:
            if let diagnostics = actions.diagnostics { SettingsDiagnosticsView(state: diagnostics, model: model, actions: actions) }
            else {
                DesignSection(eyebrow: "HEALTH") { ModalCardNote(text: "Diagnostic status is unavailable.") }
            }
        case .advanced:
            host.advancedPage
        }
    }
}
