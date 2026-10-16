import AppKit

@MainActor final class UpdateMenuSection: NSObject, MenuSection {
    private let updater: AppUpdater
    private let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { [item] }

    init(updater: AppUpdater) {
        self.updater = updater
        super.init()
        item.target = self
        item.action = #selector(check)
        refresh()
    }

    func refresh() {
        updater.refreshActivity()
        item.title = updater.hasUpdate ? "Update Available…" : "Check for Updates…"
        item.isEnabled = updater.canCheckForUpdates
    }
    @objc private func check() { updater.checkForUpdates() }
}
