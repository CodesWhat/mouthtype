import AppKit

/// Keeps the activation policy in step with the Dock setting and the windows on screen. Launches as `.accessory`
/// (the Info.plist says LSUIElement); this switches at runtime so Never is exactly the old behavior.
@MainActor final class DockPresence {
    private let mode: @MainActor () -> DockIconMode
    private let windows: @MainActor (NSWindow?) -> [DockWindowFacts]
    private let apply: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let notifications: NotificationCenter
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private(set) var policy: NSApplication.ActivationPolicy

    init(mode: @escaping @MainActor () -> DockIconMode = { DockIconMode.current() },
         windows: @escaping @MainActor (NSWindow?) -> [DockWindowFacts] = { closing in NSApp.windows.map { DockWindowFacts($0, closing: closing) } },
         initial: NSApplication.ActivationPolicy = .accessory,
         apply: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = DockPresence.applyToApp,
         notifications: NotificationCenter = .default) {
        self.mode = mode
        self.windows = windows
        self.policy = initial
        self.apply = apply
        self.notifications = notifications
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    /// Applies the saved mode now and follows window changes from here on.
    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
        for name in names {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { self?.refresh(closing: closing) }
            })
        }
        refresh()
    }

    /// Re-decides the policy. `closing` is a window that is still on screen but on its way out.
    func refresh(closing: NSWindow? = nil) {
        let target = mode().policy(windows: windows(closing))
        guard target != policy else { return }
        policy = target
        apply(target)
    }

    /// Going regular re-activates and re-keys the window the switch can knock out of key. Going accessory does
    /// nothing else, so the app that gets focus next keeps it.
    static func applyToApp(_ policy: NSApplication.ActivationPolicy) {
        let key = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        guard policy == .regular, let key, key.canBecomeMain else { return }
        NSApp.activate(ignoringOtherApps: true)
        key.makeKeyAndOrderFront(nil)
    }
}
