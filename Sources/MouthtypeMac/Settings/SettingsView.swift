import AppKit
import SwiftUI
import MouthtypeCore

/// The Settings window content: a 210 pt sidebar and a grouped-form page under a 46 pt header bar. `solid` swaps the
/// glass sidebar for an opaque fill (Reduce Transparency, and offscreen renders where glass cannot draw).
struct SettingsView: View {
    @Bindable var model: SettingsModel
    var actions = SettingsActions()
    var solid = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: SettingsTheme.sidebarWidth)
            VStack(spacing: 0) {
                header
                SettingsForm {
                    switch model.page {
                    case .general: general
                    case .writing: writing
                    case .appearance: appearance
                    case .diagnostics:
                        if let diagnostics = actions.diagnostics { SettingsDiagnosticsView(state: diagnostics, model: model, actions: actions) }
                        else { SettingsGroup(eyebrow: "DIAGNOSTICS") { SettingsNote(text: "Diagnostic status is unavailable.") } }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }
        .font(SettingsFont.sans(SettingsFont.body))
        .foregroundStyle(.primary)
        .tint(SettingsTheme.control)
        .ignoresSafeArea()
        .frame(minWidth: SettingsTheme.minimumSize.width, minHeight: SettingsTheme.minimumSize.height)
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
            HStack(spacing: 8) {
                if let url = Bundle.module.url(forResource: "mouthtype", withExtension: "png", subdirectory: "Settings"),
                   let mark = NSImage(contentsOf: url) {
                    Image(nsImage: mark).resizable().interpolation(.none).frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                }
                Text("mouthtype").font(SettingsFont.serif(SettingsFont.wordmark))
            }.padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    sidebarRow(page.title, icon: page.icon, selected: model.page == page, id: "settings-page-" + page.rawValue) { model.page = page }
                }
            }
            .focusable().focusEffectDisabled()
            .onKeyPress(.upArrow) { model.page = model.page.moved(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.page = model.page.moved(by: 1); return .handled }
            Text("YOUR WORDS").font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSidebarLink.words) { link in linkRow(link) }
            }
            Spacer(minLength: 12)
            linkRow(.setUp)
            Text("ON YOUR MAC · \(AppInfo.version)").font(SettingsFont.mono(SettingsFont.footer)).tracking(1).lineSpacing(4)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 18)
        }.padding(.horizontal, 10).frame(maxHeight: .infinity, alignment: .topLeading)
            .background { if solid { Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.04)) } }
            .overlay(alignment: .trailing) { if solid { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) } }
    }

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
