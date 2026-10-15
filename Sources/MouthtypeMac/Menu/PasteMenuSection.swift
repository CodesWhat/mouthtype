import AppKit

@MainActor
final class PasteMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let frontApp: @MainActor () -> (bundleID: String, name: String)?
    private let parent = NSMenuItem(title: "Paste Options", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Split Long Pastes", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "Paste Shortcut", action: nil, keyEquivalent: "")
    private var chordItems: [PasteChord: NSMenuItem] = [:]
    private var targetBundle: String?
    var items: [NSMenuItem] { [parent] }

    init(defaults: UserDefaults = .standard, frontApp: @escaping @MainActor () -> (bundleID: String, name: String)? = {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? id)
    }) {
        self.defaults = defaults
        self.frontApp = frontApp
        super.init()
        let menu = NSMenu(title: "Paste Options")
        menu.autoenablesItems = false
        let shortcuts = NSMenu(title: "Paste Shortcut")
        shortcuts.autoenablesItems = false
        for chord in PasteChord.allCases {
            let item = NSMenuItem(title: chord.title, action: #selector(selectChord(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = chord.rawValue
            shortcuts.addItem(item)
            chordItems[chord] = item
        }
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
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
        targetBundle = app?.bundleID
        shortcutItem.title = app.map { "Paste Shortcut for \($0.name)" } ?? "Paste Shortcut (Focus an App)"
        shortcutItem.isEnabled = targetBundle != nil
        let selected = PasteSettings.chord(for: targetBundle, defaults: defaults)
        for (chord, item) in chordItems {
            item.isEnabled = targetBundle != nil
            item.state = chord == selected ? .on : .off
        }
        let terminal = PasteSettings.supportsChunking(targetBundle)
        toggle.title = terminal ? "Split Long Pastes in \(app?.name ?? "Terminal")" : "Split Long Pastes (Focus a Terminal App)"
        toggle.isEnabled = terminal
        toggle.state = PasteSettings.chunksEnabled(targetBundle, defaults: defaults) ? .on : .off
    }

    @objc private func selectChord(_ sender: NSMenuItem) {
        guard let targetBundle, let raw = sender.representedObject as? String,
              let chord = PasteChord(rawValue: raw) else { return }
        PasteSettings.setChord(chord, bundleID: targetBundle, defaults: defaults)
        for (candidate, item) in chordItems { item.state = candidate == chord ? .on : .off }
    }

    @objc private func toggleChunks() {
        guard let targetBundle, PasteSettings.supportsChunking(targetBundle) else { return }
        PasteSettings.setChunks(!PasteSettings.chunksEnabled(targetBundle, defaults: defaults), bundleID: targetBundle, defaults: defaults)
        toggle.state = PasteSettings.chunksEnabled(targetBundle, defaults: defaults) ? .on : .off
    }
}
