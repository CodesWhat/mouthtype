import AppKit

@MainActor final class AttentionMenuSection: NSObject, MenuSection {
    private let diagnostics: SettingsDiagnostics
    private let open: @MainActor () -> Void
    private let item = NSMenuItem()
    var items: [NSMenuItem] { refresh(); return item.isHidden ? [] : [item] }

    init(diagnostics: SettingsDiagnostics, open: @escaping @MainActor () -> Void) {
        self.diagnostics = diagnostics
        self.open = open
        super.init()
        item.target = self
        item.action = #selector(showDiagnostics)
        refresh()
    }

    func refresh() {
        let text = diagnostics.attentionText
        item.title = text ?? ""
        item.isHidden = text == nil
    }

    @objc private func showDiagnostics() { open() }
}
