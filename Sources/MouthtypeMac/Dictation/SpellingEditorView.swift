import AppKit
import MouthtypeCore
import SwiftUI
import UniformTypeIdentifiers

/// The Dictionary page body: suggestions on top, then the search row and the saved words. New word and Edit word open as a
/// sheet. The page that hosts it supplies the header and the scrolling.
struct SpellingEditorView: View {
    @Bindable var editor: SpellingEditor
    var suggestions: SpellingSuggestionsModel
    var expandFirstSuggestion = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SpellingSuggestionsSection(model: suggestions, editor: editor, expandFirst: expandFirstSuggestion)
            library
            Text("Works with Basic, Fast and Thorough. Cleanup Off leaves your words unchanged.")
                .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .sheet(isPresented: Binding(get: { editor.isEditing }, set: { if !$0 { editor.cancel() } })) {
            SpellingWordSheet(editor: editor)
        }
        .sheet(isPresented: $editor.showingImport, onDismiss: editor.cancelImport) {
            SpellingImportView(editor: editor).frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 560)
        }
        .onDisappear { if !editor.isDirty { editor.cancel() } }
    }

    private var visibleWords: [SpellingWord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return editor.words }
        return editor.words.filter { word in
            word.written.localizedCaseInsensitiveContains(needle) || word.heardForms.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let message = editor.importMessage {
                Label(message, systemImage: "checkmark.circle").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.isEditing, let error = editor.error {
                Label(error, systemImage: "exclamationmark.circle").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DesignCard {
                columnHeader
                if editor.items.isEmpty {
                    emptyNote("Add a name or term that Mouthtype gets wrong.")
                } else if visibleWords.isEmpty {
                    emptyNote("No words match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                } else {
                    ForEach(visibleWords) { word in wordRow(word) }
                }
            }
            HStack {
                Button("Reload Library") { editor.reload() }.buttonStyle(.designSecondary).disabled(editor.isDirty)
                    .accessibilityLabel("Reload library")
                Spacer(minLength: 0)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DesignPalette.ink3).accessibilityHidden(true)
                TextField("Search \(editor.words.count) word\(editor.words.count == 1 ? "" : "s")", text: $query)
                    .textFieldStyle(.plain).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink)
                    .accessibilityLabel("Search words").accessibilityIdentifier("spelling-search")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
            Button { chooseCSV() } label: { Text("Import CSV…").frame(minHeight: 32) }
                .buttonStyle(.designSecondary).disabled(editor.isDirty || editor.loadFailed)
                .accessibilityLabel("Import CSV").accessibilityIdentifier("spelling-import-csv")
            Button { editor.newSpelling() } label: {
                Label("New word", systemImage: "plus").frame(minHeight: 32)
            }
            .buttonStyle(.designPrimary).disabled(editor.isDirty || editor.loadFailed)
            .accessibilityLabel("New word").accessibilityIdentifier("spelling-new-word")
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 24, height: 1).accessibilityHidden(true)
            Text("Written").designEyebrow().frame(width: 160, alignment: .leading)
            Text("Heard as").designEyebrow().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).accessibilityHidden(true)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .accessibilityIdentifier(editor.items.isEmpty ? "spelling-list-empty" : "spelling-search-empty")
    }

    private func wordRow(_ word: SpellingWord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { editor.toggleStar(word) } label: {
                Image(systemName: word.starred ? "star.fill" : "star").font(.system(size: 13))
                    .foregroundStyle(word.starred ? DesignPalette.orange : DesignPalette.hair)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(editor.isDirty || editor.loadFailed)
            .accessibilityLabel(word.starred ? "Favoured while recognising: \(word.written)" : "Favour \(word.written) while recognising")
            .accessibilityAddTraits(word.starred ? .isSelected : [])
            Button { editor.select(word) } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text(word.written).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true).frame(width: 160, alignment: .leading)
                    HeardFlow(spacing: 6) {
                        ForEach(word.heardForms, id: \.self) { HeardChip(text: $0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if word.warning != nil {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(DesignPalette.orange)
                            .help(word.hasEverydayPhrase ? "Everyday phrase" : "Everyday word")
                            .accessibilityLabel(word.hasEverydayPhrase ? "Everyday phrase" : "Everyday word")
                    }
                }
                .padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(editor.isDirty || editor.loadFailed)
            .accessibilityLabel("Edit \(word.written), heard as \(word.heardForms.joined(separator: ", "))")
        }
        .padding(.horizontal, 16).frame(minHeight: 40)
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
}

/// A heard form in the mono chip style.
struct HeardChip: View {
    let text: String
    var body: some View {
        Text(text).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(DesignPalette.sel))
    }
}

/// Lays children left to right and wraps onto new lines instead of truncating or overflowing.
struct HeardFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: layout.sizes[index].width, height: layout.sizes[index].height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins, sizes)
    }
}

/// The New word / Edit word sheet.
struct SpellingWordSheet: View {
    @Bindable var editor: SpellingEditor
    @State private var confirmDelete = false
    @FocusState private var focus: Field?
    private enum Field { case written, heard }

    private var isNew: Bool { editor.original.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DesignEyebrow(isNew ? "New word" : "Edit word")
                Spacer()
                DesignCloseButton(label: "Close without saving") { editor.cancel() }
            }
            Text(isNew ? "Save a spelling." : "Change a spelling.").font(DesignFont.serif(24)).foregroundStyle(DesignPalette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text("Written").font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
                TextField("For example, Mouthtype", text: $editor.written).textFieldStyle(.plain)
                    .font(DesignFont.sans(14)).foregroundStyle(DesignPalette.ink)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .written ? DesignPalette.focus : DesignPalette.hair, lineWidth: focus == .written ? 2 : 1))
                    .focused($focus, equals: .written).onSubmit { focus = .heard }
                    .accessibilityLabel("Written").accessibilityIdentifier("spelling-written")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Heard as").font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
                HeardFlow(spacing: 6) {
                    ForEach(editor.heardForms, id: \.self) { form in
                        HStack(spacing: 4) {
                            Text(form).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                            Button { editor.removeHeardForm(form) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                                    .frame(width: 18, height: 18).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Remove \(form)")
                        }
                        .padding(.leading, 8).padding(.trailing, 4).frame(minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.sel))
                    }
                    TextField(editor.heardForms.isEmpty ? "For example, mouth type" : "Another, then Return", text: $editor.heardInput)
                        .textFieldStyle(.plain).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink)
                        .frame(width: 160).padding(.horizontal, 4)
                        .focused($focus, equals: .heard).onSubmit { editor.commitHeardInput() }
                        .accessibilityLabel("Heard as").accessibilityIdentifier("spelling-heard")
                }
                .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .heard ? DesignPalette.focus : DesignPalette.hair, lineWidth: focus == .heard ? 2 : 1))
                Text("What Mouthtype hears when you say it. Matches whole words and phrases, regardless of capitalization. Leave it empty to fix the written form only.")
                    .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Favour while recognising").font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                    Text("Puts this word first in the speech model, so it's right before cleanup. Needs Boost saved words, under Advanced.")
                        .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Favour while recognising", isOn: $editor.starred).labelsHidden().toggleStyle(.designSwitch)
                    .accessibilityIdentifier("spelling-favour")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            messages
            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.designSecondary)
                        .disabled(editor.isDirty || editor.loadFailed).accessibilityLabel("Delete this word")
                } else {
                    Text("⌘↩ SAVES · ESC CANCELS").font(DesignFont.mono(10)).tracking(0.8).foregroundStyle(DesignPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel") { editor.cancel() }.buttonStyle(.designSecondary).keyboardShortcut(.cancelAction)
                Button("Save") { editor.commitHeardInput(); editor.save() }.buttonStyle(.designPrimary)
                    .keyboardShortcut(.return, modifiers: .command).disabled(!editor.canSave)
                    .accessibilityLabel("Save spelling").accessibilityIdentifier("spelling-save")
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
        .frame(width: 500).background(DesignPalette.bg)
        .onAppear { focus = .written }
        .confirmationDialog("Delete this spelling?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Spelling", role: .destructive) { editor.delete() }
        } message: { Text("Your other saved spellings will stay in the library.") }
    }

    @ViewBuilder private var messages: some View {
        if let warning = editor.everydayWarning {
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(DesignPalette.orange)
                .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("spelling-everyday-warning")
        }
        if let error = editor.error ?? editor.validationMessage {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
