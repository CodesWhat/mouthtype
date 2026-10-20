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
        panel.title = "Clean Up Selection"
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

    func present(transform: TextTransform? = nil, tone: StylePreset? = nil) {
        model.prepare(transform: transform, tone: tone)
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
            Text(model.transform?.title ?? model.tone.map { "\($0.title) tone" } ?? "Clean Up Selection").font(.title2.bold())
            Text("Original").font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(model.original).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: textHeight(model.original, width: 576, minimum: 22,
                                         maximum: max(22, min(120, (maximumContentHeight - 240) / 3))))
            Text("Preview").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.result).font(.body).disabled(!model.isEditable)
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
        SystemClipboard().write(model.result)
    }

    private func textHeight(_ text: String, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text + " ", attributes: [.font: NSFont.preferredFont(forTextStyle: .body)])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(maximum, max(minimum, ceil(bounds.height) + 8))
    }
}

/// The Clean Up Selection submenu: Clean Up (the focused app's tone), the three tones, the saved phrases, and a way
/// into the Transforms page. The actions need a readable selection, so they disable when there is none.
@MainActor final class SelectionCleanupMenuSection: NSObject, MenuSection, NSMenuDelegate {
    static let title = "Clean Up Selection"
    private let cleanUp: () -> Void
    private let applyTone: (StylePreset) -> Void
    private let insertPhrase: (Snippet) -> Void
    private let editTransforms: () -> Void
    private let phrases: () -> [Snippet]
    private let capture: () -> MenuCapture
    private let parent = NSMenuItem(title: SelectionCleanupMenuSection.title, action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: SelectionCleanupMenuSection.title)
    var items: [NSMenuItem] { [parent] }

    init(cleanUp: @escaping () -> Void, applyTone: @escaping (StylePreset) -> Void,
         insertPhrase: @escaping (Snippet) -> Void, editTransforms: @escaping () -> Void,
         phrases: @escaping () -> [Snippet] = { [] }, capture: @escaping () -> MenuCapture = { .ready }) {
        self.cleanUp = cleanUp
        self.applyTone = applyTone
        self.insertPhrase = insertPhrase
        self.editTransforms = editTransforms
        self.phrases = phrases
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
        add("Clean Up", #selector(runCleanUp), enabled: enabled)
        submenu.addItem(.separator())
        for preset in StylePreset.allCases {
            add(preset.title.capitalized, #selector(runTone(_:)), enabled: enabled, object: preset.rawValue)
        }
        let saved = phrases()
        if !saved.isEmpty {
            submenu.addItem(.separator())
            for phrase in saved {
                add(HistoryMenuSection.shortened(phrase.trigger), #selector(runPhrase(_:)), enabled: enabled,
                    object: phrase, tip: phrase.expansion)
            }
        }
        submenu.addItem(.separator())
        add("Edit Transforms…", #selector(runEdit), enabled: true)
    }

    @objc private func runCleanUp() { cleanUp() }
    @objc private func runTone(_ sender: NSMenuItem) {
        guard let preset = (sender.representedObject as? String).flatMap(StylePreset.init(rawValue:)) else { return }
        applyTone(preset)
    }
    @objc private func runPhrase(_ sender: NSMenuItem) {
        guard let phrase = sender.representedObject as? Snippet else { return }
        insertPhrase(phrase)
    }
    @objc private func runEdit() { editTransforms() }
}
