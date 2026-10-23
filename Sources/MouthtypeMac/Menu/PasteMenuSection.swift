import AppKit

@MainActor
final class PasteMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let frontApp: @MainActor () -> (bundleID: String, name: String)?
    private let parent = NSMenuItem(title: "Paste Options", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Split Long Pastes", action: nil, keyEquivalent: "")
    private var targetBundle: String?
    var items: [NSMenuItem] { [parent] }

    init(
        defaults: UserDefaults = .standard,
        frontApp: @escaping @MainActor () -> (bundleID: String, name: String)? = {
            guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
            return (id, app.localizedName ?? id)
        }
    ) {
        self.defaults = defaults
        self.frontApp = frontApp
        super.init()
        let menu = NSMenu(title: "Paste Options")
        menu.autoenablesItems = false
        toggle.target = self
        toggle.action = #selector(toggleChunks)
        menu.addItem(toggle)
        let detail = NSMenuItem(title: "Off by default. Applies to this terminal app’s windows.", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        parent.submenu = menu
        refresh()
    }

    func refresh() {
        let app = frontApp()
        if let app, PasteSettings.supportsChunking(app.bundleID) {
            targetBundle = app.bundleID
            toggle.title = "Split Long Pastes in \(app.name)"
        } else {
            targetBundle = nil
            toggle.title = "Split Long Pastes (Focus a Terminal App)"
        }
        toggle.isEnabled = targetBundle != nil
        toggle.state = PasteSettings.chunksEnabled(targetBundle, defaults: defaults) ? .on : .off
    }

    @objc private func toggleChunks() {
        guard let targetBundle else { return }
        PasteSettings.setChunks(!PasteSettings.chunksEnabled(targetBundle, defaults: defaults), bundleID: targetBundle, defaults: defaults)
        toggle.state = PasteSettings.chunksEnabled(targetBundle, defaults: defaults) ? .on : .off
    }
}
