import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SpellingEditorWindow: NSWindowController, NSWindowDelegate {
    let editor: SpellingEditor

    init(store: FileVocabulary) {
        editor = SpellingEditor(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Saved Spellings"
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SpellingEditorView(editor: editor))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        editor.reload()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this unsaved spelling?"
        alert.informativeText = "Save it before closing, or discard the draft."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.cancel()
        return true
    }
}

struct SpellingEditorView: View {
    @Bindable var editor: SpellingEditor
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved spellings").font(.custom("InstrumentSerif-Regular", size: 34))
                Text("Keep names and terms spelled the way you want.").foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                library.frame(width: 240)
                Divider()
                form.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            Text("Works with Basic, Fast and Thorough. Cleanup Off leaves your words unchanged.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 13)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $editor.showingImport, onDismiss: editor.cancelImport) {
            SpellingImportView(editor: editor).frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 560)
        }
        .confirmationDialog("Delete this spelling?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Spelling", role: .destructive) { editor.delete() }
        } message: { Text("Your other saved spellings will stay in the library.") }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SAVED SPELLINGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(editor.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { editor.newSpelling() } label: { Label("New Spelling", systemImage: "plus") }
                .disabled(editor.isDirty || editor.loadFailed)
            Button("Import CSV…", systemImage: "square.and.arrow.down") { chooseCSV() }
                .disabled(editor.isDirty || editor.loadFailed)
                .accessibilityIdentifier("spelling-import-csv")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if editor.items.isEmpty {
                        Text("Add a name or term that Mouthtype gets wrong.")
                            .foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                    ForEach(editor.items, id: \.heard) { rule in
                        Button { editor.select(rule) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.heard).fontWeight(.medium)
                                Text("→ " + rule.written).font(.callout).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(editor.original == rule ? Color.accentColor.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(editor.isDirty)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Reload Library") { editor.reload() }.disabled(editor.isDirty).font(.callout)
        }.padding(18)
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a UTF-8 CSV to preview. Nothing is imported until you confirm."
        panel.prompt = "Preview"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.previewImport(fileURL: url)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(editor.original == nil ? "New spelling" : "Edit spelling").font(.title3.weight(.semibold))
                        Spacer()
                        if editor.isDirty { Text("Unsaved changes").font(.callout).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Heard as").fontWeight(.medium)
                        TextField("For example, mouth type", text: $editor.heard).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Heard as").accessibilityIdentifier("spelling-heard")
                        Text("Enter the word or phrase Mouthtype gets wrong.").font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Write as").fontWeight(.medium)
                        TextField("For example, Mouthtype", text: $editor.written).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Write as").accessibilityIdentifier("spelling-written")
                        Text("Matches whole words and phrases, regardless of capitalization. Use a specific phrase for ambiguous words.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }
            if let message = editor.importMessage {
                Label(message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if let error = editor.error ?? editor.validationMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            HStack {
                if editor.original != nil {
                    Button("Delete", role: .destructive) { confirmDelete = true }.disabled(editor.isDirty || editor.loadFailed)
                }
                Spacer()
                Button("Cancel") { editor.cancel() }.disabled(!editor.isDirty)
                Button("Save Spelling") { editor.save() }.buttonStyle(.borderedProminent).disabled(!editor.canSave)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }
    }
}
