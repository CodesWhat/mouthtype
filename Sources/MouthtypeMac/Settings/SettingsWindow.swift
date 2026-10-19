import AppKit
import SwiftUI
import MouthtypeCore

@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    static let contentSize = SettingsTheme.windowSize
    static let minimumContentSize = SettingsTheme.minimumSize

    let model: SettingsModel
    private let refreshDiagnostics: () -> Void
    private let actions: SettingsActions
    private let reduceTransparency: () -> Bool
    private let fullKeyboardAccess: @MainActor () -> Bool
    private let notifications: NotificationCenter
    private nonisolated(unsafe) var transparencyObserver: NSObjectProtocol?
    var isObservingTransparency: Bool { transparencyObserver != nil }

    init(model: SettingsModel, actions: SettingsActions = SettingsActions(),
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         fullKeyboardAccess: @escaping @MainActor () -> Bool = SettingsView.systemFullKeyboardAccess,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.model = model
        self.fullKeyboardAccess = fullKeyboardAccess
        self.actions = actions
        self.reduceTransparency = reduceTransparency
        self.notifications = notifications
        refreshDiagnostics = actions.refreshDiagnostics
        let window = SettingsNSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Mouthtype Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        super.init(window: window)
        applyContent()
        window.setContentSize(Self.contentSize)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let transparencyObserver { notifications.removeObserver(transparencyObserver) }
    }

    /// Installs the glass or solid sidebar to match Reduce Transparency. Called at init and again whenever the setting changes.
    private func applyContent() {
        guard let window else { return }
        let solid = reduceTransparency()
        let hosting = NSHostingView(rootView: SettingsView(model: model, actions: actions, solid: solid, fullKeyboardAccess: fullKeyboardAccess))
        hosting.sizingOptions = []
        if solid {
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
        } else {
            window.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            window.contentView = glass
        }
    }

    private func startObservingTransparency() {
        guard transparencyObserver == nil else { return }
        transparencyObserver = notifications.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let size = window.contentView?.frame.size
                self.applyContent()
                if let size { window.setContentSize(size) }
            }
        }
    }

    func present(page: SettingsPage? = nil) {
        startObservingTransparency()
        if let page { model.page = page }
        refreshDiagnostics()
        model.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        startObservingTransparency()
        refreshDiagnostics()
        model.refresh()
    }
}

/// The Settings window. The app runs without a main menu, so nothing supplies Cmd-W; handle it here.
final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Shift-Tab. SwiftUI links the hosted controls forward only, so AppKit's own backward walk skips from a page control to the
    /// end of the window. Step back through the forward Tab order instead, which is the order Tab already follows.
    override func selectKeyView(preceding view: NSView) {
        guard let previous = SettingsKeyLoop.previous(of: view, in: contentView) else { return super.selectKeyView(preceding: view) }
        makeFirstResponder(previous)
    }
}

/// The Settings window's Tab order, walked forward from the content view.
@MainActor enum SettingsKeyLoop {
    static func order(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        var views: [NSView] = []
        var current = root.nextValidKeyView
        while let view = current, view !== root, !views.contains(where: { $0 === view }) {
            views.append(view)
            current = view.nextValidKeyView
        }
        return views
    }

    /// The control before `view` in Tab order, wrapping from the first to the last. Nil when `view` is not in the loop.
    static func previous(of view: NSView, in root: NSView?) -> NSView? {
        let order = order(in: root)
        guard let index = order.firstIndex(where: { $0 === view }), !order.isEmpty else { return nil }
        return order[(index - 1 + order.count) % order.count]
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, writing, appearance, diagnostics
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The page `offset` rows away, stopping at the first and last pages.
    func moved(by offset: Int) -> SettingsPage {
        let pages = Self.allCases
        let index = pages.firstIndex(of: self) ?? 0
        return pages[min(max(index + offset, 0), pages.count - 1)]
    }
    /// Arrow keys step from the focused sidebar row when there is one, else from the selected page.
    static func arrowTarget(focused: SettingsPage?, selected: SettingsPage, offset: Int) -> SettingsPage {
        (focused ?? selected).moved(by: offset)
    }
    var icon: String {
        switch self { case .general: "slider.horizontal.3"; case .writing: "textformat"; case .appearance: "paintpalette"; case .diagnostics: "stethoscope" }
    }
    var headline: String {
        switch self {
        case .general: "A little less typing."
        case .writing: "Your words. Your way."
        case .appearance: "Clean by default. Personal by choice."
        case .diagnostics: "Keep things moving."
        }
    }
    var summary: String {
        switch self {
        case .general: "Set your shortcut, choose your cleanup, and carry on."
        case .writing: "A finish that feels right, without changing what you mean."
        case .appearance: "The same Mouthtype underneath. A different little machine when you want one."
        case .diagnostics: "Model progress, permissions and input. Repairs in one place."
        }
    }
}

/// Sidebar entries that open something instead of selecting a page.
enum SettingsSidebarLink: String, CaseIterable, Identifiable {
    case savedSpellings, phrases, setUp
    var id: String { rawValue }
    var title: String {
        switch self { case .savedSpellings: "Saved spellings"; case .phrases: "Phrases"; case .setUp: "Set Up Mouthtype…" }
    }
    var icon: String {
        switch self { case .savedSpellings: "character.book.closed"; case .phrases: "text.badge.plus"; case .setUp: "checklist" }
    }
    var accessibilityID: String {
        switch self { case .savedSpellings: "settings-spellings"; case .phrases: "settings-phrases"; case .setUp: "settings-setup" }
    }
    /// The sidebar's "YOUR WORDS" group.
    static let words: [SettingsSidebarLink] = [.savedSpellings, .phrases]
}

@MainActor struct SettingsActions {
    var openSetup: () -> Void = {}
    var changeShortcut: () -> Void = {}
    var openSpellings: () -> Void = {}
    var openPhrases: () -> Void = {}
    var cleaner: (any CleanupModelManaging)?
    var diagnostics: SettingsDiagnostics?
    var retrySpeech: () -> Void = {}
    var refreshDiagnostics: () -> Void = {}
    var toggleRemap: () -> Void = {}
    var openMicSettings: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var openKeyboardSettings: () -> Void = {}
    var editDictionary: () -> Void = {}
    var editPhrasesFile: () -> Void = {}
    var chooseFont: () -> Void = {}
    var updater: AppUpdater?

    func perform(_ link: SettingsSidebarLink) {
        switch link {
        case .savedSpellings: openSpellings()
        case .phrases: openPhrases()
        case .setUp: openSetup()
        }
    }
}
