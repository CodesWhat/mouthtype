import AppKit
import SwiftUI
import MouthtypeCore

@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    static let contentSize = SettingsTheme.windowSize
    static let minimumContentSize = SettingsTheme.minimumSize

    let model: SettingsModel
    private let refreshDiagnostics: () -> Void
    private var actions: SettingsActions
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
        present(destination: page.map { .page($0) })
    }

    /// Shows the window and goes to `destination`. A page goes through `select`, so an unsaved draft still asks first.
    func present(destination: SettingsDestination?) {
        // The Transcribe window opens by itself; the Mouthtype window isn't brought up behind it.
        if destination == .transcribeFile { model.open(.transcribeFile); return }
        startObservingTransparency()
        if let destination { model.open(destination) }
        refreshDiagnostics()
        model.refresh()
        reloadHome()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        startObservingTransparency()
        refreshDiagnostics()
        model.refresh()
        reloadHome()
    }

    /// The Home log and the stats are watched only while the window is open on their pages.
    func windowWillClose(_ notification: Notification) {
        model.home.deactivate()
        model.stats.deactivate()
        model.deactivateWords()
    }

    /// The window a new sheet or panel should attach to: the Mouthtype window, or the Settings sheet when one is up,
    /// so nested editors open on top of it rather than queueing behind it.
    var topmostWindow: NSWindow? {
        var top = window
        while let sheet = top?.attachedSheet { top = sheet }
        return top
    }

    /// Closing with an unsaved spelling or phrase draft asks first, as the separate editor windows did.
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.resolveDraft(.closing) }

    /// Quit never reaches windowShouldClose, so the app asks here. With an unsaved draft the window comes forward on its page first.
    func resolveDraftForQuit() -> Bool {
        guard model.unsavedDraft != nil else { return true }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        return model.resolveDraft(.quitting)
    }

    private func reloadHome() {
        let home = model.home
        if model.page == .home {
            home.activate()
            home.startReload()
        } else {
            home.deactivate()
        }
        let stats = model.stats
        if model.page == .stats {
            stats.activate()
        } else {
            stats.deactivate()
        }
        model.syncWords()
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
        focusByKeyboard(previous)
    }

    /// True while a Tab, Shift-Tab or key view step is moving focus, so mouse clicks don't jump the page.
    private var isMovingFocusByKeyboard = false

    override func selectNextKeyView(_ sender: Any?) { keyboardStep { super.selectNextKeyView(sender) } }
    override func selectPreviousKeyView(_ sender: Any?) { keyboardStep { super.selectPreviousKeyView(sender) } }
    override func selectKeyView(following view: NSView) { keyboardStep { super.selectKeyView(following: view) } }

    private func keyboardStep(_ body: () -> Void) {
        let was = isMovingFocusByKeyboard
        isMovingFocusByKeyboard = true
        defer { isMovingFocusByKeyboard = was }
        body()
    }

    /// Moves focus the way Tab does, which also scrolls the page to the new control.
    @discardableResult func focusByKeyboard(_ view: NSView) -> Bool {
        var moved = false
        keyboardStep { moved = makeFirstResponder(view) }
        return moved
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let moved = super.makeFirstResponder(responder)
        if moved, isMovingFocusByKeyboard, let responder { scrollFocusIntoView(responder) }
        return moved
    }

    /// Scrolls the page so the focused control is on screen with a small margin. The sidebar rows always fit, so they're left alone.
    private func scrollFocusIntoView(_ responder: NSResponder) {
        var target = responder as? NSView
        if let editor = responder as? NSText, editor.isFieldEditor, let owner = editor.delegate as? NSView { target = owner }
        guard let view = target, view.enclosingScrollView != nil,
              view.convert(view.bounds, to: nil).minX >= SettingsTheme.sidebarWidth else { return }
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -12))
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

@MainActor struct SettingsActions {
    var openSetup: () -> Void = {}
    var changeShortcut: () -> Void = {}
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

}
