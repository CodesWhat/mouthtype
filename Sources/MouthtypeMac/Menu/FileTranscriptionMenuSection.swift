import AppKit

@MainActor final class FileTranscriptionMenuSection: NSObject, MenuSection {
    private let open: @MainActor () -> Void
    private let item = NSMenuItem(title: "Transcribe Audio File…", action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { [item] }

    init(open: @escaping @MainActor () -> Void) {
        self.open = open
        super.init()
        item.target = self
        item.action = #selector(present)
    }
    @objc private func present() { open() }
}
