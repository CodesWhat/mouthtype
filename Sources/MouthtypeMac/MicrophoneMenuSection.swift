import AppKit
import AVFoundation

@MainActor
final class MicrophoneMenuSection: NSObject, MenuSection {
    private let item = NSMenuItem()
    private let status: @MainActor () -> AVAuthorizationStatus
    private var previousStatus: AVAuthorizationStatus?
    var onStatusChanged: (@MainActor (AVAuthorizationStatus) -> Void)?
    var items: [NSMenuItem] { [item] }

    init(status: @escaping @MainActor () -> AVAuthorizationStatus = { MicrophoneAccess.status }) {
        self.status = status
        super.init()
        item.target = self
        refresh()
    }

    func refresh() {
        let current = status()
        item.title = MicrophoneAccess.statusText(for: current)
        item.isEnabled = current != .authorized
        item.action = current == .authorized ? nil : #selector(openSettings)
        if current != previousStatus {
            previousStatus = current
            onStatusChanged?(current)
        }
    }

    @objc private func openSettings() { NSWorkspace.shared.open(MicrophoneAccess.settingsURL) }
}
