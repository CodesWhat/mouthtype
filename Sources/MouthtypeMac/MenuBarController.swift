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
    private let stopItem = NSMenuItem(title: "Stop Dictation", action: nil, keyEquivalent: "")
    private let cancelItem = NSMenuItem(title: "Cancel Dictation", action: nil, keyEquivalent: "")
    private var handsFree = false

    /// The menu's stand-ins for the key tap and Esc while a recording is locked and the pill can't be clicked.
    var onStopDictation: (@MainActor () -> Void)?
    var onCancelDictation: (@MainActor () -> Void)?

    public init(engineHost: EngineHost, version: String = AppInfo.version) {
        self.engineHost = engineHost
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setIcon(.idle)
        menu.delegate = self
        for (item, action) in [(stopItem, #selector(stopDictation)), (cancelItem, #selector(cancelDictation))] {
            item.target = self
            item.action = action
        }
        statusItem.menu = menu
        rebuildMenu(version: version)
        observeEngineState()
    }

    func setIcon(_ icon: StatusIcon) {
        statusItem.button?.image = icon.image
    }

    /// Puts Stop Dictation and Cancel Dictation at the top of the menu while a recording is locked.
    func setHandsFree(_ active: Bool) {
        handsFree = active
        rebuildMenu(version: AppInfo.version)
    }

    var dictationControlItems: [NSMenuItem] { [stopItem, cancelItem] }

    @objc private func stopDictation() { onStopDictation?() }
    @objc private func cancelDictation() { onCancelDictation?() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
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
        if handsFree {
            menu.addItem(stopItem)
            menu.addItem(cancelItem)
            menu.addItem(.separator())
        }
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
        let about = NSMenuItem(title: "About Mouthtype", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
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
