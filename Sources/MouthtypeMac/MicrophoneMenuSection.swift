import AppKit
import AVFoundation

@MainActor
final class MicrophoneMenuSection: MenuSection {
    private let item = NSMenuItem()
    var items: [NSMenuItem] { [item] }

    init() {
        item.isEnabled = false
        refresh()
    }

    func refresh() {
        item.title = MicrophoneAccess.statusText(for: MicrophoneAccess.status)
    }
}
