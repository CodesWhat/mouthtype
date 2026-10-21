import AppKit
import MouthtypeCore
import os

/// The Transform Selection submenu: the five transforms the panel offers as chips, then a way into the Transforms page.
/// Each transform opens the panel with that choice made. They need a readable selection, so they disable when there is
/// none, and the AI ones also disable while the Thorough model is missing.
@MainActor final class TransformSelectionMenuSection: NSObject, MenuSection, NSMenuDelegate {
    static let title = "Transform Selection"
    private let open: (TextTransform?) -> Void
    private let editTransforms: () -> Void
    private let aiUnavailableReason: () -> String?
    private let capture: @MainActor () async -> MenuCapture
    private let parent = NSMenuItem(title: TransformSelectionMenuSection.title, action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: TransformSelectionMenuSection.title)
    private var state = MenuCapture.ready
    private var generation = 0
    /// The read for the current menu open. Tests await it.
    private(set) var pendingCapture: Task<Void, Never>?
    private static let signposter = OSSignposter(subsystem: "com.codeswhat.mouthtype", category: "menu")
    var items: [NSMenuItem] { [parent] }

    /// `open` gets nil for Clean up and the AI transform otherwise.
    init(open: @escaping (TextTransform?) -> Void, editTransforms: @escaping () -> Void,
         aiUnavailableReason: @escaping () -> String? = { nil }, capture: @escaping @MainActor () async -> MenuCapture = { .ready }) {
        self.open = open
        self.editTransforms = editTransforms
        self.aiUnavailableReason = aiUnavailableReason
        self.capture = capture
        super.init()
        submenu.autoenablesItems = false
        submenu.delegate = self
        parent.submenu = submenu
        rebuild(.ready)
    }

    /// The selection is read as the status menu is about to open and only then, not on every refresh. It can't wait for the
    /// submenu to open: by then the menu is tracking and the system-wide focused element is empty, so a system-wide read
    /// finds nothing and every item comes up disabled. The read goes to the frontmost app instead, which still reports its own focus.
    /// The read runs off the main actor, so the menu opens at once with the items disabled and they enable when the
    /// result lands. Disabled is the safe default: nothing can act on a selection nobody has checked yet. An item that is
    /// enabled still re-reads the selection when it runs, and the panel refuses if it differs from what the menu saw.
    func prepareForMenuOpen() {
        pendingCapture?.cancel()
        generation += 1
        let id = generation
        let started = ContinuousClock.now
        let signpost = Self.signposter.beginInterval("menuSelectionRead")
        state = .reading
        apply(state)
        let mainBlocked = started.duration(to: .now)
        pendingCapture = Task { [weak self, capture] in
            let result = await capture()
            guard let self, !Task.isCancelled, id == self.generation else {
                Self.signposter.endInterval("menuSelectionRead", signpost, "dropped")
                return
            }
            self.state = result
            self.apply(result)
            Self.signposter.endInterval("menuSelectionRead", signpost, "\(String(describing: result))")
            Log.app.info("menu selection read: main blocked \(mainBlocked.formatted()), result in \(started.duration(to: .now).formatted()): \(String(describing: result))")
        }
    }

    func menuDidClose() {
        generation += 1
        pendingCapture?.cancel()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(state) }

    /// Updates the open submenu in place when only enablement changed, so items don't get torn out from under the pointer.
    private func apply(_ state: MenuCapture) {
        guard (state == .timedOut) == showsNote else { return rebuild(state) }
        let enabled = state == .ready
        let reason = aiUnavailableReason()
        for item in submenu.items where !item.isSeparatorItem {
            if item.action == #selector(runEdit) { continue }
            let isAI = item.representedObject != nil
            item.isEnabled = enabled && (!isAI || reason == nil)
            item.toolTip = isAI ? reason : nil
        }
    }

    private var showsNote = false

    private func rebuild(_ state: MenuCapture) {
        let enabled = state == .ready
        showsNote = state == .timedOut
        submenu.removeAllItems()
        if state == .timedOut {
            let note = NSMenuItem(title: "Couldn’t read the selection", action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
            submenu.addItem(.separator())
        }
        func add(_ title: String, _ action: Selector, enabled: Bool, object: Any? = nil, tip: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = object
            item.toolTip = tip
            submenu.addItem(item)
        }
        add("Clean up", #selector(runTransform(_:)), enabled: enabled)
        let reason = aiUnavailableReason()
        for kind in TextTransform.allCases {
            add(kind.chipTitle, #selector(runTransform(_:)), enabled: enabled && reason == nil, object: kind.rawValue, tip: reason)
        }
        submenu.addItem(.separator())
        add("Edit Transforms…", #selector(runEdit), enabled: true)
    }

    @objc private func runTransform(_ sender: NSMenuItem) {
        open((sender.representedObject as? String).flatMap(TextTransform.init(rawValue:)))
    }
    @objc private func runEdit() { editTransforms() }
}
