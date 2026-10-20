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
        item.isEnabled = updater.canCheckForUpdates
    }
    @objc private func check() { updater.checkForUpdates() }
}

/// The attention line shown at the top of the menu while an update is waiting. Hidden otherwise.
@MainActor final class UpdateAvailableMenuSection: NSObject, MenuSection {
    private let updater: AppUpdater
    private let item = NSMenuItem(title: "Update Available…", action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { refresh(); return item.isHidden ? [] : [item] }

    init(updater: AppUpdater) {
        self.updater = updater
        super.init()
        item.target = self
        item.action = #selector(install)
        refresh()
    }

    func refresh() {
        item.isHidden = !updater.hasUpdate
        item.isEnabled = updater.canCheckForUpdates
    }
    @objc private func install() { updater.checkForUpdates() }
}
