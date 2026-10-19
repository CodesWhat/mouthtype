import AppKit
import MouthtypeCore
import SwiftUI

@MainActor final class SelectionCleanupWindow: NSWindowController, NSWindowDelegate {
    let model: SelectionCleanupModel
    private let maximumContentHeight: CGFloat

    init(model: SelectionCleanupModel, maximumContentHeight: CGFloat? = nil) {
        self.model = model
        self.maximumContentHeight = max(260, min(620, maximumContentHeight ?? ((NSScreen.main?.visibleFrame.height ?? 684) - 64)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clean Selected Text"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SelectionCleanupView(model: model,
            maximumContentHeight: self.maximumContentHeight,
            close: { [weak self] in self?.close() }, resize: { [weak self] in self?.resizeToFitContent() }))
        resizeToFitContent()
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(transform: TextTransform? = nil) {
        model.prepare(transform: transform)
        resizeToFitContent()
        // The original app keeps activation so Accept can check its exact selection.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    private func resizeToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        window.setContentSize(NSSize(width: fitting.width, height: min(maximumContentHeight, fitting.height)))
    }
}

private struct SelectionCleanupView: View {
    @Bindable var model: SelectionCleanupModel
    var maximumContentHeight: CGFloat
    var close: () -> Void
    var resize: () -> Void
    private var compact: Bool { maximumContentHeight < 320 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(model.transform?.title ?? "Clean selected text").font(.title2.bold())
            Text("Original").font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(model.original).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: textHeight(model.original, width: 576, minimum: 22,
                                         maximum: max(22, min(120, (maximumContentHeight - 240) / 3))))
            Text("Preview").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.result).font(.body).disabled(!model.hasPreview || model.submitted)
                .frame(height: textHeight(model.result, width: 552, minimum: 44,
                                         maximum: max(44, min(240, (maximumContentHeight - 240) * 2 / 3 - 12))))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityIdentifier("selection-cleanup-preview")
            Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: close)
                Menu("Transform") {
                    Button("Basic cleanup", action: model.chooseBasic).disabled(!model.canChooseBasic)
                    Divider()
                    ForEach(TextTransform.allCases, id: \.self) { kind in
                        Button(kind.title) { model.choose(kind) }
                    }
                }.disabled(!model.canChooseTransform && !model.canChooseBasic)
                    .help(model.transformUnavailableReason ?? "Run an AI transform on the selected text with the local model.")
                    .fixedSize()
                    .accessibilityIdentifier("selection-cleanup-transform")
                Button("Retry", action: model.retry).disabled(!model.canRetry)
                    .accessibilityIdentifier("selection-cleanup-retry")
                Spacer()
                if model.submitted && model.transform != nil {
                    Button("Copy original", action: copyOriginal)
                }
                Button("Copy result", action: copyResult).disabled(model.result.isEmpty || model.isTransforming)
                Button("Accept", action: model.accept).disabled(!model.canAccept)
                    .accessibilityIdentifier("selection-cleanup-accept")
            }
        }.padding(compact ? 16 : 22).frame(width: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: model.result) { resize() }
            .onChange(of: model.message) { resize() }
            .alert("Couldn’t replace selected text", isPresented: $model.acceptanceErrorPresented) {
                Button("Copy result", action: copyResult)
                Button("Keep preview", role: .cancel) {}
            } message: {
                Text(model.message)
            }
    }

    private func copyOriginal() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.original, forType: .string)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.result, forType: .string)
    }

    private func textHeight(_ text: String, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text + " ", attributes: [.font: NSFont.preferredFont(forTextStyle: .body)])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(maximum, max(minimum, ceil(bounds.height) + 8))
    }
}

@MainActor final class SelectionCleanupMenuSection: NSObject, MenuSection, NSMenuDelegate {
    private let open: () -> Void
    private let openTransform: (TextTransform) -> Void
    private let unavailableReason: () -> String?
    private let item = NSMenuItem(title: "Clean Selected Text…", action: nil, keyEquivalent: "")
    private let transformItem = NSMenuItem(title: "Transform Selected Text", action: nil, keyEquivalent: "")
    private let transformMenu = NSMenu(title: "Transform Selected Text")
    private let reasonItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var transformItems: [NSMenuItem] = []
    var items: [NSMenuItem] { [item, transformItem] }

    init(open: @escaping () -> Void, openTransform: @escaping (TextTransform) -> Void = { _ in },
         unavailableReason: @escaping () -> String? = { "AI transforms aren’t available in this build." }) {
        self.open = open
        self.openTransform = openTransform
        self.unavailableReason = unavailableReason
        super.init()
        item.target = self
        item.action = #selector(present)
        transformMenu.autoenablesItems = false
        transformMenu.delegate = self
        transformMenu.addItem(reasonItem)
        reasonItem.isEnabled = false
        for (index, kind) in TextTransform.allCases.enumerated() {
            let entry = NSMenuItem(title: kind.title, action: #selector(presentTransform(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            transformMenu.addItem(entry)
            transformItems.append(entry)
        }
        transformItem.submenu = transformMenu
        update()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update() }
    func refresh() { update() }

    private func update() {
        let reason = unavailableReason()
        reasonItem.title = reason ?? ""
        reasonItem.isHidden = reason == nil
        for entry in transformItems { entry.isEnabled = reason == nil }
    }

    @objc private func present() { open() }
    @objc private func presentTransform(_ sender: NSMenuItem) {
        guard TextTransform.allCases.indices.contains(sender.tag) else { return }
        openTransform(TextTransform.allCases[sender.tag])
    }
}
