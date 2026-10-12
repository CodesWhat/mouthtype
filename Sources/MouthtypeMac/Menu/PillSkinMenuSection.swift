import AppKit

/// The Pill Style submenu: one radio item per skin, applied to the live pill as soon as it's picked.
@MainActor
final class PillSkinMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let onSelect: @MainActor (PillSkinKind) -> Void
    private let parent = NSMenuItem(title: "Pill Style", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Pill Style")
    private var skinItems: [PillSkinKind: NSMenuItem] = [:]

    var items: [NSMenuItem] { [parent] }

    init(defaults: UserDefaults = .standard, onSelect: @escaping @MainActor (PillSkinKind) -> Void) {
        self.defaults = defaults
        self.onSelect = onSelect
        super.init()
        for kind in PillSkinKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            submenu.addItem(item)
            skinItems[kind] = item
        }
        parent.submenu = submenu
        refresh()
    }

    func refresh() {
        let current = PillSkinPreference.current(defaults)
        for (kind, item) in skinItems { item.state = kind == current ? .on : .off }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let kind = (sender.representedObject as? String).flatMap(PillSkinKind.init(rawValue:)) else { return }
        PillSkinPreference.set(kind, in: defaults)
        refresh()
        onSelect(kind)
    }
}
