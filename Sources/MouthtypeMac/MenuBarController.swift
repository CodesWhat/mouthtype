import AppKit

@MainActor
public protocol MenuSection {
    var items: [NSMenuItem] { get }
    func refresh()
}

extension MenuSection {
    public func refresh() {}
}

@MainActor final class DailyMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var sections: [(section: any MenuSection, startsGroup: Bool, isFooter: Bool)] = []
    private let stopItem = NSMenuItem(title: "Stop Dictation", action: nil, keyEquivalent: "")
    private let cancelItem = NSMenuItem(title: "Cancel Dictation", action: nil, keyEquivalent: "")
    private let aboutItem = NSMenuItem(title: "About Mouthtype", action: nil, keyEquivalent: "")
    private var handsFree = false
    var onStopDictation: (@MainActor () -> Void)?
    var onCancelDictation: (@MainActor () -> Void)?
    var onRefresh: (@MainActor () -> Void)?
    var dictationControlItems: [NSMenuItem] { [stopItem, cancelItem] }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        for (item, action) in [(stopItem, #selector(stop)), (cancelItem, #selector(cancel)), (aboutItem, #selector(about))] {
            item.target = self
            item.action = action
        }
        rebuild()
    }

    func add(section: any MenuSection, startsGroup: Bool = true, isFooter: Bool = false) {
        sections.append((section, startsGroup, isFooter))
        rebuild()
    }

    func setHandsFree(_ active: Bool) { handsFree = active; rebuild() }
    func refresh() {
        onRefresh?()
        sections.forEach { $0.section.refresh() }
        rebuild()
    }
    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func rebuild() {
        menu.removeAllItems()
        var groups: [[NSMenuItem]] = []
        if handsFree { groups.append([stopItem, cancelItem]) }
        for entry in sections where !entry.isFooter {
            let visible = entry.section.items.filter { !$0.isHidden && !$0.isSeparatorItem }
            guard !visible.isEmpty else { continue }
            if entry.startsGroup || groups.isEmpty { groups.append(visible) }
            else { groups[groups.count - 1].append(contentsOf: visible) }
        }
        let footer = sections.filter(\.isFooter).flatMap { $0.section.items.filter { !$0.isHidden && !$0.isSeparatorItem } } + [aboutItem, NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]
        groups.append(footer)
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    @objc private func stop() { onStopDictation?() }
    @objc private func cancel() { onCancelDictation?() }
    @objc private func about() { NSApp.activate(); NSApp.orderFrontStandardAboutPanel(nil) }
}

@MainActor public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let daily = DailyMenu()
    var onStopDictation: (@MainActor () -> Void)? {
        get { daily.onStopDictation } set { daily.onStopDictation = newValue }
    }
    var onCancelDictation: (@MainActor () -> Void)? {
        get { daily.onCancelDictation } set { daily.onCancelDictation = newValue }
    }
    var onRefresh: (@MainActor () -> Void)? {
        get { daily.onRefresh } set { daily.onRefresh = newValue }
    }
    var dictationControlItems: [NSMenuItem] { daily.dictationControlItems }

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setIcon(.idle)
        statusItem.menu = daily.menu
    }

    func setIcon(_ icon: StatusIcon) { statusItem.button?.image = icon.image }
    func setHandsFree(_ active: Bool) { daily.setHandsFree(active) }
    public func refresh() { daily.refresh() }
    public func add(section: any MenuSection, startsGroup: Bool = true, isFooter: Bool = false) { daily.add(section: section, startsGroup: startsGroup, isFooter: isFooter) }
}
