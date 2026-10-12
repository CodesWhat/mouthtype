import AppKit
import Observation

/// Owns the status item. Later slices add sections through `MenuSection`s without touching this class.
@MainActor
public protocol MenuSection {
    var items: [NSMenuItem] { get }
    /// Re-reads whatever the items show. Called when the menu opens and after each dictation.
    func refresh()
}

extension MenuSection {
    public func refresh() {}
}

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let engineHost: EngineHost
    private let engineStatusItem = NSMenuItem()
    private let menu = NSMenu()
    private var sections: [any MenuSection] = []

    public init(engineHost: EngineHost, version: String = AppInfo.version) {
        self.engineHost = engineHost
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setIcon(.idle)
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(version: version)
        observeEngineState()
    }

    func setIcon(_ icon: StatusIcon) {
        statusItem.button?.image = icon.image
    }

    /// Re-reads every section and rebuilds the menu. Call after each finished dictation.
    public func refresh() {
        sections.forEach { $0.refresh() }
        rebuildMenu(version: AppInfo.version)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    public func add(section: any MenuSection) {
        sections.append(section)
        rebuildMenu(version: AppInfo.version)
    }

    private func rebuildMenu(version: String) {
        // Items are reused across rebuilds and an NSMenuItem can only be in one menu.
        menu.removeAllItems()
        let title = NSMenuItem(title: "Mouthtype \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        engineStatusItem.isEnabled = false
        engineStatusItem.title = engineHost.state.statusText
        menu.addItem(engineStatusItem)
        for section in sections {
            menu.addItem(.separator())
            section.items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func observeEngineState() {
        withObservationTracking {
            engineStatusItem.title = engineHost.state.statusText
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEngineState() }
        }
    }
}
