import AppKit

/// The Text Font submenu: the Systema set and the system designs as radio items, and Choose Font… for any installed
/// family through the standard font panel. A pick applies to the pill and the card as soon as it's made.
@MainActor
final class TextFontMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let parent = NSMenuItem(title: "Text Font", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Text Font")
    private var choiceItems: [(choice: TextFontChoice, item: NSMenuItem)] = []
    private let customItem = NSMenuItem(title: "Choose Font\u{2026}", action: nil, keyEquivalent: "")

    var items: [NSMenuItem] { [parent] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        for choice in TextFontChoice.standard {
            let item = NSMenuItem(title: choice.title, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
            choiceItems.append((choice, item))
        }
        submenu.addItem(.separator())
        customItem.target = self
        customItem.action = #selector(chooseFont(_:))
        submenu.addItem(customItem)
        parent.submenu = submenu
        refresh()
    }

    func refresh() {
        let current = TextFontPreference.current(defaults)
        for (choice, item) in choiceItems { item.state = choice == current ? .on : .off }
        if case .custom(let family) = current {
            customItem.state = .on
            customItem.title = "Choose Font\u{2026} (\(family))"
        } else {
            customItem.state = .off
            customItem.title = "Choose Font\u{2026}"
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let choice = choiceItems.first(where: { $0.item === sender })?.choice else { return }
        TextFontPreference.set(choice, in: defaults)
        refresh()
    }

    @objc private func chooseFont(_ sender: NSMenuItem) { presentFontChooser() }

    func presentFontChooser() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        let typography = Typography.current(defaults)
        manager.setSelectedFont(typography.font(.body), isMultiple: false)
        NSApp.activate()
        manager.orderFrontFontPanel(self)
    }

    /// The font panel's pick. Only the family is kept; the roles pick the size and weight.
    @objc func changeFont(_ sender: NSFontManager?) {
        let manager = sender ?? NSFontManager.shared
        let picked = manager.convert(Typography.current(defaults).font(.body))
        guard let family = picked.familyName, !family.isEmpty else { return }
        TextFontPreference.set(.custom(family), in: defaults)
        refresh()
    }
}
