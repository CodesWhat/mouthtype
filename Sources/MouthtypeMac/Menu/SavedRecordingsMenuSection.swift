import AppKit
import MouthtypeCore

@MainActor
final class SavedRecordingsMenuSection: NSObject, MenuSection, NSMenuDelegate {
    private let parent = NSMenuItem(title: "Saved Recordings", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Saved Recordings")
    private let recovery: CrashRecovery
    private let canRecover: @MainActor () -> Bool
    private let load: @MainActor () async throws -> [RecoverableDictation]
    private var saved: [RecoverableDictation] = []
    private var page = 0
    private var generation = 0
    private var loading = false
    private static let pageSize = 20
    var items: [NSMenuItem] { [parent] }

    init(recovery: CrashRecovery, canRecover: @escaping @MainActor () -> Bool,
         load: (@MainActor () async throws -> [RecoverableDictation])? = nil) {
        self.recovery = recovery
        self.canRecover = canRecover
        self.load = load ?? { try await recovery.loadSavedRecordings() }
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        parent.submenu = submenu
        showMessage("Open to load saved recordings")
    }

    func refresh() {
        let enabled = canRecover() && !recovery.isRecovering
        for item in submenu.items where item.representedObject is RecoverableDictation {
            item.isEnabled = enabled
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        generation += 1
        let current = generation
        loading = true
        showMessage("Loading saved recordings…")
        let load = load
        Task { [weak self] in
            do {
                let recordings = try await load()
                guard let self, generation == current else { return }
                saved = recordings
                page = min(page, max(0, (saved.count - 1) / Self.pageSize))
                loading = false
                showPage()
            } catch {
                guard let self, generation == current else { return }
                loading = false
                Log.app.error("saved recordings unavailable: \(error.localizedDescription, privacy: .public)")
                showMessage("Saved recordings unavailable")
            }
        }
    }

    private func showMessage(_ title: String) {
        submenu.removeAllItems()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        submenu.addItem(item)
    }

    private func showPage() {
        guard !loading else { return }
        submenu.removeAllItems()
        let start = min(page * Self.pageSize, saved.count)
        let end = min(start + Self.pageSize, saved.count)
        for recording in saved[start..<end] {
            let date = recording.startedAt.formatted(date: .abbreviated, time: .shortened)
            let item = NSMenuItem(title: "\(date) · \(DeliveryCard.durationText(recording.seconds))", action: #selector(selectRecording(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = recording
            submenu.addItem(item)
        }
        if saved.isEmpty { showMessage("No saved recordings") }
        if page > 0 { addNavigation("Newer recordings", action: #selector(newer)) }
        if end < saved.count { addNavigation("Older recordings", action: #selector(older)) }
        refresh()
    }

    private func addNavigation(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        submenu.addItem(item)
    }

    @objc private func older() { page += 1; showPage() }
    @objc private func newer() { page = max(0, page - 1); showPage() }

    @objc private func selectRecording(_ sender: NSMenuItem) {
        guard canRecover(), let recording = sender.representedObject as? RecoverableDictation else { return }
        recovery.offerSaved(recording)
    }
}
