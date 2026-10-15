import AppKit
import SwiftUI
import MouthtypeCore

@MainActor
final class PhraseEditorWindow: NSWindowController, NSWindowDelegate {
    let editor: PhraseEditor

    init(store: FilePhrases) {
        editor = PhraseEditor(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Phrase Replacements"
        window.minSize = NSSize(width: 800, height: 540)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PhraseEditorView(editor: editor))
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
        alert.messageText = "Discard this unsaved phrase?"
        alert.informativeText = "Save it before closing, or discard the draft."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.cancel()
        return true
    }
}

struct PhraseEditorView: View {
    @Bindable var editor: PhraseEditor
    @State private var confirmDelete = false
    private let paper = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phrase replacements").font(.custom("InstrumentSerif-Regular", size: 34))
                Text("Say a short phrase. Insert exactly the text you saved.")
                    .foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                library.frame(width: 252)
                Divider()
                form.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            Text("Works with Basic, Fast and Thorough. Cleanup Off leaves your words unchanged.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 13)
        }
        .background(paper)
        .confirmationDialog("Delete this phrase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Phrase", role: .destructive) { editor.delete() }
        } message: { Text("Your other saved phrases will stay in the library.") }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SAVED PHRASES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(editor.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { editor.newPhrase() } label: { Label("New Phrase", systemImage: "plus") }
                .disabled(editor.isDirty || editor.loadFailed)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if editor.items.isEmpty {
                        Text("Your library starts here. Add an email address, a signature, or text you use often.")
                            .foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                    ForEach(editor.items, id: \.trigger) { phrase in
                        Button { editor.select(phrase) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(phrase.trigger).fontWeight(.medium)
                                Text(phrase.expansion).font(.callout).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(editor.original == phrase ? Color.accentColor.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(editor.isDirty)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Reload Library") { editor.reload() }.disabled(editor.isDirty)
                .font(.callout)
        }.padding(18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { fields.padding(24) }
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            HStack {
                if editor.original != nil {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .disabled(editor.isDirty || editor.loadFailed)
                }
                Spacer()
                Button("Cancel") { editor.cancel() }.disabled(!editor.isDirty)
                Button("Save Phrase") { editor.save() }.buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editor.original == nil ? "New phrase" : "Edit phrase").font(.title3.weight(.semibold))
                Spacer()
                if editor.isDirty { Text("Unsaved changes").font(.callout).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("When I say").fontWeight(.medium)
                TextField("For example, my work email", text: $editor.trigger).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("phrase-trigger")
                Text("Matches whole phrases, regardless of capitalization.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Insert").fontWeight(.medium)
                TextEditor(text: $editor.expansion)
                    .font(.system(.body, design: .monospaced)).padding(6)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("Replacement text").accessibilityIdentifier("phrase-expansion")
                HStack {
                    Button("Add Date") { editor.expansion += "{date}" }
                    Button("Add Clipboard") { editor.expansion += "{clipboard}" }
                }.controlSize(.small)
                Text("{date} uses today’s date. {clipboard} uses the clipboard text captured for this dictation, or nothing if it’s empty.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
