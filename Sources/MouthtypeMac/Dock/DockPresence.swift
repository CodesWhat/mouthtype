import AppKit

/// Keeps the activation policy in step with the Dock setting and the windows on screen. Launches as `.accessory`
/// (the Info.plist says LSUIElement); this switches at runtime so Never is exactly the old behavior.
@MainActor final class DockPresence {
    private let mode: @MainActor () -> DockIconMode
    private let windows: @MainActor (NSWindow?) -> [DockWindowFacts]
    private let apply: @MainActor (NSApplication.ActivationPolicy, NSWindow?) -> Void
    private let notifications: NotificationCenter
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private(set) var policy: NSApplication.ActivationPolicy

    init(mode: @escaping @MainActor () -> DockIconMode = { DockIconMode.current() },
         windows: @escaping @MainActor (NSWindow?) -> [DockWindowFacts] = { closing in NSApp.windows.map { DockWindowFacts($0, closing: closing) } },
         initial: NSApplication.ActivationPolicy = .accessory,
         apply: @escaping @MainActor (NSApplication.ActivationPolicy, NSWindow?) -> Void = { DockPresence.applyToApp($0, closing: $1) },
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
        apply(target, closing)
    }

    /// Going regular re-activates and re-keys the window the switch can knock out of key. Going accessory can hide
    /// windows that should survive and deactivate the app, so it records what was up and puts it back.
    static func applyToApp(_ policy: NSApplication.ActivationPolicy, closing: NSWindow?) {
        let key = NSApp.keyWindow
        let wasActive = NSApp.isActive
        let survivors = NSApp.windows.filter { $0 !== closing && $0.isVisible && ($0.canBecomeMain || $0 is NSPanel) }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            guard let key, key.canBecomeMain else { return }
            NSApp.activate(ignoringOtherApps: true)
            key.makeKeyAndOrderFront(nil)
            return
        }
        let plan = DockRestorePlan.make(
            visible: survivors.map { DockSurvivor(id: ObjectIdentifier($0), canTakeKey: Self.canTakeKey($0)) },
            wasActive: wasActive, key: key.map(ObjectIdentifier.init))
        // Right away, not on a later turn: a window dismissed in between must stay dismissed.
        for window in survivors where plan.restore.contains(ObjectIdentifier(window)) { window.orderFrontRegardless() }
        guard plan.activate else { return }
        NSApp.activate(ignoringOtherApps: true)
        survivors.first { plan.key == ObjectIdentifier($0) }?.makeKeyAndOrderFront(nil)
    }

    /// A regular window, or a panel that isn't nonactivating, can take focus. A pill or card can't.
    private static func canTakeKey(_ window: NSWindow) -> Bool {
        guard window.canBecomeKey else { return false }
        guard let panel = window as? NSPanel else { return true }
        return !panel.styleMask.contains(.nonactivatingPanel)
    }
}

/// One window that survives the switch, and whether it could be given focus.
struct DockSurvivor<ID: Hashable>: Equatable {
    var id: ID
    var canTakeKey: Bool
}

/// What to put back after the policy drops to accessory. Windows that were hidden or closing aren't in `visible`, so
/// they stay that way. The app is activated only if it was active and a survivor can take focus, so a floating panel,
/// pill or card never takes focus from the user's target app.
struct DockRestorePlan<ID: Hashable>: Equatable {
    var restore: [ID]
    var activate: Bool
    var key: ID?

    static func make(visible: [DockSurvivor<ID>], wasActive: Bool, key: ID?) -> DockRestorePlan {
        let focusable = visible.filter(\.canTakeKey).map(\.id)
        return DockRestorePlan(restore: visible.map(\.id), activate: wasActive && !focusable.isEmpty,
                               key: wasActive ? key.flatMap { focusable.contains($0) ? $0 : nil } : nil)
    }
}
