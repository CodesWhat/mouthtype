import AppKit

@MainActor final class ActionsMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let onPasteLast: @MainActor () -> Void
    private let onCopyLast: @MainActor () -> Void
    private let pasteItem = NSMenuItem(title: "Paste Last", action: nil, keyEquivalent: "v")
    private let copyItem = NSMenuItem(title: "Copy Last", action: nil, keyEquivalent: "c")
    var items: [NSMenuItem] { [pasteItem, copyItem] }

    init(defaults: UserDefaults = .standard,
         onPasteLast: @escaping @MainActor () -> Void, onCopyLast: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.onPasteLast = onPasteLast
        self.onCopyLast = onCopyLast
        super.init()
        for item in items { item.keyEquivalentModifierMask = [.command, .control]; item.target = self }
        pasteItem.action = #selector(pasteLast)
        copyItem.action = #selector(copyLast)
        refresh()
    }
    func refresh() {
        let shortcut = ShortcutSettings.load(defaults)
        pasteItem.keyEquivalent = shortcut?.claimsLastAction(keyCode: 9) == true ? "" : "v"
        copyItem.keyEquivalent = shortcut?.claimsLastAction(keyCode: 8) == true ? "" : "c"
    }
    @objc private func pasteLast() { onPasteLast() }
    @objc private func copyLast() { onCopyLast() }
}
