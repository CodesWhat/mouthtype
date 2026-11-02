import AppKit

/// The Edit Selection by Voice command. It is only ever started from this item or the optional shortcut, never from
/// ordinary dictation. It stays enabled; the flow itself refuses with a plain reason when there is nothing to edit.
@MainActor final class VoiceEditMenuSection: NSObject, MenuSection {
    static let title = "Edit Selection by Voice"
    private let open: @MainActor () -> Void
    private let item = NSMenuItem(title: VoiceEditMenuSection.title, action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { [item] }

    init(open: @escaping @MainActor () -> Void) {
        self.open = open
        super.init()
        item.target = self
        item.action = #selector(run)
    }

    @objc private func run() { open() }
}
