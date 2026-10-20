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
    /// A custom action rather than `terminate:`, since macOS 26 gives standard-action items a system icon and this menu is plain text.
    private let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")
    private var handsFree = false
    var onStopDictation: (@MainActor () -> Void)?
    var onCancelDictation: (@MainActor () -> Void)?
    var onRefresh: (@MainActor () -> Void)?
    var dictationControlItems: [NSMenuItem] { [stopItem, cancelItem] }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        for (item, action) in [(stopItem, #selector(stop)), (cancelItem, #selector(cancel)), (aboutItem, #selector(about)), (quitItem, #selector(quit))] {
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
        let footer = sections.filter(\.isFooter).flatMap { $0.section.items.filter { !$0.isHidden && !$0.isSeparatorItem } } + [aboutItem, quitItem]
        groups.append(footer)
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    @objc private func stop() { onStopDictation?() }
    @objc private func cancel() { onCancelDictation?() }
    @objc private func quit() { NSApp.terminate(nil) }
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
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.applyGlyph()
            }
        }
        setIcon(.idle)
        statusItem.menu = daily.menu
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private var icon = StatusIcon.idle
    private var level: Float = 0
    private var gate = StatusGlyphGate()
    private var reduceMotion = false
    private nonisolated(unsafe) var accessibilityObserver: NSObjectProtocol?
    private let images: [String: NSImage] = Dictionary(
        uniqueKeysWithValues: (StatusIcon.allCases.filter { $0 != .recording }.map(\.glyphName) + StatusIcon.recordingFiles)
            .compactMap { name in StatusIcon.loadImage(named: name).map { (name, $0) } })

    /// `--status-icon recording` pins a static recording glyph for screenshots, so the level doesn't animate it.
    var isPinned = false

    /// The glyph file currently committed to the status item.
    var currentGlyphFile: String? { gate.file }

    func setIcon(_ icon: StatusIcon) {
        if icon != .recording { level = 0 }
        self.icon = icon
        applyGlyph()
    }

    /// The pill's smoothed meter level, 0...1. Only the recording icon follows it.
    func setLevel(_ level: Float) {
        self.level = level
        if icon == .recording, !isPinned { applyGlyph() }
    }

    private func applyGlyph() {
        guard let file = gate.next(
            icon: icon, level: level, reduceMotion: reduceMotion || isPinned,
            now: ProcessInfo.processInfo.systemUptime, canShow: { images[$0] != nil }),
              let image = images[file] else { return }
        statusItem.button?.image = image
    }
    func setHandsFree(_ active: Bool) { daily.setHandsFree(active) }
    public func refresh() { daily.refresh() }
    public func add(section: any MenuSection, startsGroup: Bool = true, isFooter: Bool = false) { daily.add(section: section, startsGroup: startsGroup, isFooter: isFooter) }
}
