import AppKit
import SwiftUI

@MainActor final class SelectionCleanupWindow: NSWindowController, NSWindowDelegate {
    let model: SelectionCleanupModel

    init(model: SelectionCleanupModel) {
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clean Selected Text"
        panel.minSize = NSSize(width: 560, height: 420)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SelectionCleanupView(model: model, close: { [weak self] in self?.close() }))
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        model.prepare()
        // The original app keeps activation so Accept can check its exact selection.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }
}

private struct SelectionCleanupView: View {
    @Bindable var model: SelectionCleanupModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean selected text").font(.title2.bold())
            Text("Original").font(.headline)
            ScrollView { Text(model.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 120)
            Text("Preview").font(.headline)
            TextEditor(text: $model.result).font(.body).disabled(!model.hasPreview || model.submitted)
                .accessibilityIdentifier("selection-cleanup-preview")
            Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: close)
                Spacer()
                Button("Copy result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.result, forType: .string)
                }.disabled(model.result.isEmpty)
                Button("Accept", action: model.accept).disabled(!model.canAccept)
                    .accessibilityIdentifier("selection-cleanup-accept")
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor final class SelectionCleanupMenuSection: NSObject, MenuSection {
    private let open: () -> Void
    private let item = NSMenuItem(title: "Clean Selected Text…", action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { [item] }

    init(open: @escaping () -> Void) {
        self.open = open
        super.init()
        item.target = self
        item.action = #selector(present)
    }
    @objc private func present() { open() }
}
