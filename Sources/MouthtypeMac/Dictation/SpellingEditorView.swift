import AppKit
import MouthtypeCore
import SwiftUI
import UniformTypeIdentifiers

struct SpellingEditorView: View {
    @Bindable var editor: SpellingEditor
    var suggestions: SpellingSuggestionsModel
    var expandFirstSuggestion = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpellingSuggestionsSection(model: suggestions, editor: editor, expandFirst: expandFirstSuggestion)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                library.frame(width: 240)
                Divider()
                form.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(minHeight: 320, idealHeight: 320, maxHeight: .infinity)
            Divider()
            Text("Works with Basic, Fast and Thorough. Cleanup Off leaves your words unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24).padding(.vertical, 13)
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
                                if OrdinaryWords.warning(for: rule) != nil {
                                    Label(rule.heard.contains(where: \.isWhitespace) ? "Everyday phrase" : "Everyday word", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
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
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            editor.previewImport(fileURL: url)
        }
        // A sheet blocks the window, so the page can't change while the picker is open.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
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
            if let warning = editor.everydayWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("spelling-everyday-warning")
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
