import AppKit

@MainActor final class SettingsMenuSection: NSObject, MenuSection {
    private let open: @MainActor () -> Void
    private let openHome: @MainActor () -> Void
    private let homeItem = NSMenuItem(title: "Open Mouthtype", action: nil, keyEquivalent: "")
    private let item = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
    var items: [NSMenuItem] { [homeItem, item] }

    /// `openHome` lands on the Home page. `open` is Settings…, which lands on General.
    init(open: @escaping @MainActor () -> Void, openHome: @escaping @MainActor () -> Void = {}) {
        self.open = open
        self.openHome = openHome
        super.init()
        homeItem.target = self
        homeItem.action = #selector(presentHome)
        item.target = self
        item.action = #selector(presentSettings)
    }

    func applicationMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            parent.submenu = submenu
            main.addItem(parent)
        }
        let home = NSMenuItem(title: "Open Mouthtype", action: #selector(presentHome), keyEquivalent: "")
        home.target = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(presentSettings), keyEquivalent: ",")
        settings.target = self
        add("Mouthtype", [home, settings, .separator(), NSMenuItem(title: "Quit Mouthtype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        add("File", [NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        add(
            "Edit",
            [
                NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
                .separator(),
                NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            ])
        return main
    }

    @objc private func presentSettings() { open() }
    @objc private func presentHome() { openHome() }
}
