import AppKit
import SwiftUI
import MouthtypeCore

/// The Transforms page body: a "When you say" card with one row per saved phrase and a New transform row, then an "On selected text"
/// card that lists the menu bar transforms. A phrase row opens the sheet, so the draft, save, cancel and delete rules are the editor's own.
/// Long text clips to one line with a fade at the edge, never an ellipsis.
struct PhraseEditorView: View {
    @Bindable var editor: PhraseEditor
    /// The Thorough model's state, for the status on each AI transform. Nil where the page is built without a model, as in most tests.
    var transformModel: CleanupSelection?
    @State private var sheetOpen = false

    private static let triggerColumn: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = editor.error, editor.loadFailed {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(DesignPalette.danger)
                        .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Reload") { editor.reload() }.buttonStyle(.designSecondary).accessibilityLabel("Reload transform library")
                }
            }
            whenYouSay
            onSelectedText
        }
        .sheet(isPresented: $sheetOpen, onDismiss: { editor.cancel() }) {
            PhraseFormSheet(editor: editor) { sheetOpen = false }
        }
    }

    // MARK: When you say

    private var whenYouSay: some View {
        DesignSection(eyebrow: "When you say") {
            ForEach(editor.items, id: \.trigger) { phrase in phraseRow(phrase) }
            addRow
        }
    }

    private func phraseRow(_ phrase: Snippet) -> some View {
        let kind = TransformKind.of(phrase)
        let result = Self.display(phrase.expansion)
        return Button {
            editor.select(phrase)
            sheetOpen = true
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: Self.triggerColumn, height: 22).overlay(alignment: .leading) {
                    Text(phrase.trigger).font(DesignFont.mono(DesignFont.caption)).foregroundStyle(DesignPalette.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(DesignPalette.c0))
                }
                .clipped().fadeEdge()
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 14).accessibilityHidden(true)
                Color.clear.frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20).overlay(alignment: .leading) {
                    Text(result.text).font(result.placeholder ? DesignFont.sans(DesignFont.body).italic() : DesignFont.sans(DesignFont.body))
                        .foregroundStyle(result.placeholder ? DesignPalette.ink2 : DesignPalette.ink)
                        .lineLimit(1).fixedSize()
                }
                .clipped().fadeEdge()
                Text(kind.title).font(DesignFont.mono(9)).tracking(0.9).foregroundStyle(DesignPalette.ink3).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 12).accessibilityHidden(true)
            }
            .padding(.leading, 14).padding(.trailing, 12).frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(editor.isDirty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edit transform \(phrase.trigger), \(kind.title.lowercased())")
        .accessibilityHint(phrase.expansion)
        .accessibilityAddTraits(.isButton)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editor.items.isEmpty {
                Text("Nothing saved yet. Add an email address, a signature, or text you use often.")
                    .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                Button { editor.newPhrase(); sheetOpen = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignPalette.accentText)
                            .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.accentSoft))
                            .accessibilityHidden(true)
                        Text("New transform").font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.accentText)
                    }
                    .padding(.leading, 6).padding(.trailing, 10).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(editor.isDirty || editor.loadFailed)
                .accessibilityLabel("New transform").accessibilityIdentifier("phrase-new")
                Spacer(minLength: 8)
                Text("Whole phrases, any capitalization. Works at every cleanup level except Off.")
                    .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing).padding(.trailing, 6)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 5)
        }
    }

    /// What a row shows for the typed text. A body that is only a placeholder reads as a description in italics, and line breaks show as ⏎.
    static func display(_ expansion: String) -> (text: String, placeholder: Bool) {
        switch expansion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "{clipboard}": return ("Whatever you copied before you started talking", true)
        case "{date}": return ("Today\u{2019}s date, like \(Date.now.formatted(date: .abbreviated, time: .omitted))", true)
        default:
            let lines = expansion.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            return (lines.joined(separator: " \u{23CE} "), false)
        }
    }

    // MARK: On selected text

    private struct MenuTransform: Identifiable {
        let id: String
        let title: String
        let detail: String
        let usesModel: Bool
    }

    private static let menuTransforms = [
        MenuTransform(id: "cleanUp", title: "Clean up", detail: "Fillers and spoken commands out. Names and numbers untouched.", usesModel: false),
        MenuTransform(id: TextTransform.fixGrammar.rawValue, title: "Fix grammar", detail: "Grammar, spelling and punctuation. Your wording stays.", usesModel: true),
        MenuTransform(id: TextTransform.shorter.rawValue, title: "Make shorter", detail: "Cuts words that add nothing. Keeps every fact and name.", usesModel: true),
        MenuTransform(id: TextTransform.moreFormal.rawValue, title: "More formal", detail: "No slang, no contractions, complete sentences.", usesModel: true),
        MenuTransform(id: TextTransform.moreCasual.rawValue, title: "More casual", detail: "Contractions and plain words.", usesModel: true),
    ]

    /// Why the AI transforms can't run, or nil when the model is ready (or the page has no model to ask).
    private var unavailableReason: String? {
        transformModel?.transformModelStatus.unavailableReason
    }

    private var onSelectedText: some View {
        DesignSection(eyebrow: "On selected text \u{00B7} from the menu bar",
            footer: "Select text in any app, then choose Transform Selection from the menu bar. You review the result before anything is replaced."
                + (unavailableReason.map { " \($0)" } ?? "")) {
            ForEach(Self.menuTransforms) { transform in
                HStack(alignment: .center, spacing: 12) {
                    Text(transform.title).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true).frame(width: Self.triggerColumn, alignment: .leading)
                    Text(transform.detail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    status(transform)
                }
                .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 6).frame(minHeight: 42)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("transform-" + transform.id)
            }
        }
    }

    @ViewBuilder private func status(_ transform: MenuTransform) -> some View {
        if !transform.usesModel {
            Text("NO MODEL \u{00B7} INSTANT").font(DesignFont.mono(9.5)).tracking(0.95).foregroundStyle(DesignPalette.ink3).fixedSize()
        } else if let status = transformModel?.transformModelStatus {
            let ready = status.isReady
            HStack(spacing: 5) {
                Circle().fill(ready ? DesignPalette.accent : DesignPalette.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("THOROUGH \u{00B7} \(status.stateWord)").font(DesignFont.mono(9.5)).tracking(0.95)
                    .foregroundStyle(DesignPalette.ink3).fixedSize()
            }
        } else {
            Text("NEEDS THOROUGH").font(DesignFont.mono(9.5)).tracking(0.95).foregroundStyle(DesignPalette.ink3).fixedSize()
        }
    }
}

private extension View {
    /// Fades the last 24 pt to nothing so a clipped line reads as continuing rather than cut off.
    func fadeEdge() -> some View {
        mask(HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
        })
    }
}

/// The New transform and Edit transform sheet.
struct PhraseFormSheet: View {
    @Bindable var editor: PhraseEditor
    var close: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editor.original == nil ? "New transform" : "Edit transform").designEyebrow()
                Spacer()
                if editor.isDirty { Text("Unsaved changes").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2) }
                DesignCloseButton(label: "Close without saving") { editor.cancel(); close() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("phrase-close")
            }
            Text("Save a transform.").font(DesignFont.serif(24)).foregroundStyle(DesignPalette.ink)
                .accessibilityAddTraits(.isHeader)
            field("When you say", note: "Matches the whole phrase, any capitalization.") {
                TextField("For example, my work email", text: $editor.trigger).textFieldStyle(.plain)
                    .font(DesignFont.sans(14)).padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                    .accessibilityLabel("When you say").accessibilityIdentifier("phrase-trigger")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Type instead").font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
                TextEditor(text: $editor.expansion).scrollContentBackground(.hidden)
                    .font(DesignFont.mono(12.5)).lineSpacing(3).padding(6).frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                    .accessibilityLabel("Type instead").accessibilityIdentifier("phrase-expansion")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button("+ Date") { editor.expansion += "{date}" }.buttonStyle(.designSecondary)
                        .accessibilityLabel("Insert date placeholder")
                    Button("+ Clipboard") { editor.expansion += "{clipboard}" }.buttonStyle(.designSecondary)
                        .accessibilityLabel("Insert clipboard placeholder")
                    Text("{date} becomes today\u{2019}s date; {clipboard} becomes whatever you copied before dictating.")
                        .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
                }
            }
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(DesignPalette.danger)
                    .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
        .frame(width: 520)
        .background(DesignPalette.bg)
        .confirmationDialog("Delete this transform?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Transform", role: .destructive) { editor.delete(); if editor.error == nil { close() } }
        } message: { Text("Your other saved transforms will stay in the library.") }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if editor.original != nil {
                Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.designSecondary)
                    .disabled(editor.isDirty || editor.loadFailed)
            }
            Text("\u{2318}\u{21A9} SAVES \u{00B7} ESC CANCELS").designEyebrow().fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { editor.cancel(); close() }.buttonStyle(.designSecondary)
            Button("Save") { editor.save(); if editor.error == nil && !editor.isDirty { close() } }
                .buttonStyle(.designPrimary).disabled(!editor.canSave)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func field<Content: View>(_ label: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
            content()
            Text(note).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
