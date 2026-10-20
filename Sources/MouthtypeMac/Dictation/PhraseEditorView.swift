import AppKit
import SwiftUI
import MouthtypeCore

/// The Transforms page body: one card listing every saved phrase with its kind, plus the built-in Clean Selected Text row. A phrase
/// opens in a sheet for editing, so the draft, save, cancel and delete rules are the editor's own.
struct PhraseEditorView: View {
    @Bindable var editor: PhraseEditor
    @State private var query = ""
    @State private var sheetOpen = false

    private static let kindColumn: CGFloat = 112
    private static let triggerColumn: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            toolbar
            if let error = editor.error, editor.loadFailed {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(DesignFont.sans(DesignFont.detail))
                    .fixedSize(horizontal: false, vertical: true)
            }
            list
            Text("Works with Basic, Fast and Thorough. Cleanup Off leaves your words unchanged.")
                .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .sheet(isPresented: $sheetOpen, onDismiss: { editor.cancel() }) {
            PhraseFormSheet(editor: editor) { sheetOpen = false }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DesignPalette.ink3).accessibilityHidden(true)
                TextField("Search \(editor.items.count) phrases", text: $query).textFieldStyle(.plain)
                    .font(DesignFont.sans(DesignFont.body)).accessibilityLabel("Search phrases").accessibilityIdentifier("phrase-search")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
            Button("Reload Library") { editor.reload() }.buttonStyle(.designSecondary).disabled(editor.isDirty)
                .accessibilityLabel("Reload phrase library")
            Button { editor.newPhrase(); sheetOpen = true } label: { Label("New phrase", systemImage: "plus") }
                .buttonStyle(.designPrimary).disabled(editor.isDirty || editor.loadFailed)
                .accessibilityLabel("New phrase").accessibilityIdentifier("phrase-new")
        }
    }

    // MARK: List

    private var list: some View {
        let phrases = editor.matching(query)
        return VStack(spacing: 0) {
            header
            DesignHairline()
            cleanSelectionRow
            if editor.items.isEmpty {
                DesignHairline()
                Text("Your library starts here. Add an email address, a signature, or text you use often.")
                    .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else if phrases.isEmpty {
                DesignHairline()
                Text("No phrases match “\(query)”.").font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(phrases, id: \.trigger) { phrase in
                DesignHairline()
                phraseRow(phrase)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Kind").frame(width: Self.kindColumn, alignment: .leading)
            Text("When I say").frame(width: Self.triggerColumn, alignment: .leading)
            Text("Inserts").frame(maxWidth: .infinity, alignment: .leading)
        }
        .designEyebrow().fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func kindBadge(_ kind: TransformKind) -> some View {
        Text(kind.title).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(kind == .text ? DesignPalette.c0 : DesignPalette.c1))
            .fixedSize()
            .frame(width: Self.kindColumn, alignment: .leading)
    }

    private func phraseRow(_ phrase: Snippet) -> some View {
        let kind = TransformKind.of(phrase)
        return Button {
            editor.select(phrase)
            sheetOpen = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                kindBadge(kind)
                Text(phrase.trigger).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).frame(width: Self.triggerColumn, alignment: .leading)
                Text(phrase.expansion).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(editor.isDirty)
        .accessibilityLabel("Edit phrase \(phrase.trigger), \(kind.title)")
        .accessibilityHint(phrase.expansion)
    }

    /// Clean Selected Text is a menu bar action with no shortcut of its own. It has to stay informational here: opening it from
    /// this window would make Mouthtype the frontmost app, and it cleans whatever is selected in the app you were using.
    private var cleanSelectionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            kindBadge(.cleanSelection)
            Text("Clean Selected Text…").font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true).frame(width: Self.triggerColumn, alignment: .leading)
            Text("Select text in any app, then choose Clean Selected Text… from the Mouthtype menu bar item. You review a preview before it replaces anything.")
                .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transform-clean-selection")
    }
}

/// The New phrase and Edit phrase sheet.
struct PhraseFormSheet: View {
    @Bindable var editor: PhraseEditor
    var close: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editor.original == nil ? "New phrase" : "Edit phrase").designEyebrow()
                Spacer()
                if editor.isDirty { Text("Unsaved changes").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2) }
                DesignCloseButton(label: "Close without saving") { editor.cancel(); close() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("phrase-close")
            }
            Text("Save a phrase.").font(DesignFont.serif(24)).foregroundStyle(DesignPalette.ink)
                .accessibilityAddTraits(.isHeader)
            field("When I say", note: "Matches whole phrases, regardless of capitalization.") {
                TextField("For example, my work email", text: $editor.trigger).textFieldStyle(.plain)
                    .font(DesignFont.sans(14)).padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                    .accessibilityLabel("When I say").accessibilityIdentifier("phrase-trigger")
            }
            field("Insert", note: "{date} uses today’s date. {clipboard} uses the clipboard text captured for this dictation, or nothing if it’s empty.") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $editor.expansion).scrollContentBackground(.hidden)
                        .font(DesignFont.mono(12)).padding(6).frame(height: 130)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                        .accessibilityLabel("Replacement text").accessibilityIdentifier("phrase-expansion")
                    HStack(spacing: 8) {
                        Button("Add Date") { editor.expansion += "{date}" }.buttonStyle(.designSecondary)
                        Button("Add Clipboard") { editor.expansion += "{clipboard}" }.buttonStyle(.designSecondary)
                    }
                }
            }
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(DesignFont.sans(DesignFont.detail))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
        .frame(width: 500)
        .background(DesignPalette.bg)
        .confirmationDialog("Delete this phrase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Phrase", role: .destructive) { editor.delete(); if editor.error == nil { close() } }
        } message: { Text("Your other saved phrases will stay in the library.") }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if editor.original != nil {
                Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.designSecondary)
                    .disabled(editor.isDirty || editor.loadFailed)
            }
            Text("⌘↩ SAVES · ESC CANCELS").designEyebrow().fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { editor.cancel(); close() }.buttonStyle(.designSecondary)
            Button("Save Phrase") { editor.save(); if editor.error == nil && !editor.isDirty { close() } }
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
