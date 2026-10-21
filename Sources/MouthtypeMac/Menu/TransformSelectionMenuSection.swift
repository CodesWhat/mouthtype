import AppKit
import MouthtypeCore

/// The Transform Selection submenu: the five transforms the panel offers as chips, then a way into the Transforms page.
/// Each transform opens the panel with that choice made. They need a readable selection, so they disable when there is
/// none, and the AI ones also disable while the Thorough model is missing.
@MainActor final class TransformSelectionMenuSection: NSObject, MenuSection, NSMenuDelegate {
    static let title = "Transform Selection"
    private let open: (TextTransform?) -> Void
    private let editTransforms: () -> Void
    private let aiUnavailableReason: () -> String?
    private let capture: () -> MenuCapture
    private let parent = NSMenuItem(title: TransformSelectionMenuSection.title, action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: TransformSelectionMenuSection.title)
    var items: [NSMenuItem] { [parent] }

    /// `open` gets nil for Clean up and the AI transform otherwise.
    init(open: @escaping (TextTransform?) -> Void, editTransforms: @escaping () -> Void,
         aiUnavailableReason: @escaping () -> String? = { nil }, capture: @escaping () -> MenuCapture = { .ready }) {
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

    /// The selection is read only when this submenu opens, never when the top-level menu refreshes, so a slow app
    /// can't hold up Settings, Stop Dictation or Quit.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(capture()) }

    private func rebuild(_ state: MenuCapture) {
        let enabled = state == .ready
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
