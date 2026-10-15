import AppKit
import MouthtypeCore

@MainActor
final class SavedRecordingsMenuSection: NSObject, MenuSection {
    private let parent = NSMenuItem(title: "Saved Recordings", action: nil, keyEquivalent: "")
    private let recovery: CrashRecovery
    private let canRecover: @MainActor () -> Bool
    var items: [NSMenuItem] { [parent] }

    init(recovery: CrashRecovery, canRecover: @escaping @MainActor () -> Bool) {
        self.recovery = recovery
        self.canRecover = canRecover
        super.init()
        refresh()
    }

    func refresh() {
        let submenu = NSMenu(title: "Saved Recordings")
        submenu.autoenablesItems = false
        do {
            let saved = try recovery.savedRecordings()
            for recording in saved {
                let date = recording.startedAt.formatted(date: .abbreviated, time: .shortened)
                let item = NSMenuItem(title: "\(date) · \(DeliveryCard.durationText(recording.seconds))", action: #selector(selectRecording(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = recording
                item.isEnabled = canRecover() && !recovery.isRecovering
                submenu.addItem(item)
            }
            if saved.isEmpty {
                let empty = NSMenuItem(title: "No saved recordings", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            }
        } catch {
            Log.app.error("saved recordings unavailable: \(error.localizedDescription, privacy: .public)")
            let unavailable = NSMenuItem(title: "Saved recordings unavailable", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        }
        parent.submenu = submenu
    }

    @objc private func selectRecording(_ sender: NSMenuItem) {
        guard canRecover(), let recording = sender.representedObject as? RecoverableDictation else { return }
        recovery.offerSaved(recording)
    }
}
