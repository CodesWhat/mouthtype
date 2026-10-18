import AppKit
import SwiftUI

@MainActor final class SelectionCleanupWindow: NSWindowController, NSWindowDelegate {
    let model: SelectionCleanupModel

    init(model: SelectionCleanupModel) {
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clean Selected Text"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SelectionCleanupView(model: model,
            close: { [weak self] in self?.close() }, resize: { [weak self] in self?.resizeToFitContent() }))
        resizeToFitContent()
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        model.prepare()
        resizeToFitContent()
        // The original app keeps activation so Accept can check its exact selection.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    private func resizeToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }
}

private struct SelectionCleanupView: View {
    @Bindable var model: SelectionCleanupModel
    var close: () -> Void
    var resize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean selected text").font(.title2.bold())
            Text("Original").font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(model.original).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: textHeight(model.original, width: 576, minimum: 22, maximum: 120))
            Text("Preview").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.result).font(.body).disabled(!model.hasPreview || model.submitted)
                .frame(height: textHeight(model.result, width: 552, minimum: 44, maximum: 240))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
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
        }.padding(22).frame(width: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: model.result) { resize() }
            .onChange(of: model.message) { resize() }
    }

    private func textHeight(_ text: String, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text + " ", attributes: [.font: NSFont.preferredFont(forTextStyle: .body)])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(maximum, max(minimum, ceil(bounds.height) + 8))
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
