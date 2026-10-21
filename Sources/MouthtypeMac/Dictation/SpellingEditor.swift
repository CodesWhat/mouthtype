import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class SpellingEditor {
    private let store: FileVocabulary
    private(set) var items: [DictionaryRule] = []
    /// The word being edited as saved, empty for a new word. A word is every rule that writes the same spelling.
    private(set) var original: [DictionaryRule] = []
    /// True while the New word / Edit word sheet is up.
    private(set) var isEditing = false
    /// Heard forms already added to the draft. Whatever is still typed in `heardInput` counts as one more.
    var heardForms: [String] = []
    var heardInput = ""
    var written = ""
    var starred = false
    private(set) var error: String?
    private(set) var loadFailed = false
    private(set) var importPreview: SpellingImportPreview?
    private(set) var importFileName = ""
    private(set) var importError: String?
    private(set) var importMessage: String?
    var showingImport = false
    /// Called after a save, delete or import changed the library file.
    @ObservationIgnored var onLibraryChanged: @MainActor () -> Void = {}
    var canImport: Bool { !isDirty && !loadFailed && importError == nil && importPreview?.canImport == true }

    func previewImport(data: Data, fileName: String) {
        guard !isDirty, !loadFailed else { return }
        cancelImport()
        importMessage = nil
        importFileName = fileName
        showingImport = true
        do { importPreview = try store.previewImport(data) }
        catch { importError = error.localizedDescription }
    }

    func previewImport(fileURL: URL) {
        guard !isDirty, !loadFailed else { return }
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            let data = try file.read(upToCount: SpellingCSV.maximumBytes + 1) ?? Data()
            previewImport(data: data, fileName: fileURL.lastPathComponent)
        } catch {
            cancelImport()
            importMessage = nil
            importFileName = fileURL.lastPathComponent
            importError = error.localizedDescription
            showingImport = true
        }
    }

    func cancelImport() {
        showingImport = false
        importPreview = nil
        importError = nil
        importFileName = ""
    }

    func confirmImport() {
        guard canImport, let preview = importPreview else { return }
        do {
            try store.importSpellings(preview)
            let count = preview.additions.count
            cancelImport()
            reload()
            onLibraryChanged()
            importMessage = "Imported \(count) spelling\(count == 1 ? "" : "s")."
        } catch FileVocabulary.WriteError.changed {
            importError = "The spelling library changed after this preview. Cancel and choose the CSV again."
        } catch { importError = error.localizedDescription }
    }

    /// The saved words, one per spelling, in the order their first rule appears in the library.
    var words: [SpellingWord] {
        var order: [String] = []
        var grouped: [String: [DictionaryRule]] = [:]
        for rule in items {
            if grouped[rule.written] == nil { order.append(rule.written) }
            grouped[rule.written, default: []].append(rule)
        }
        return order.map { SpellingWord(written: $0, rules: grouped[$0] ?? []) }
    }

    /// The heard forms that would be saved: the added ones plus what is typed, or the spelling itself when none is given,
    /// which fixes capitalisation only (the same as a CSV with a name column).
    var effectiveHeardForms: [String] {
        var forms = heardForms
        if let typed = Self.normalized(heardInput), !forms.contains(where: { Self.sameForm($0, typed) }) { forms.append(typed) }
        if forms.isEmpty, let name = Self.normalized(written) { forms = [name] }
        return forms
    }

    var isDirty: Bool {
        let saved = original.map(\.heard)
        return written != (original.first?.written ?? "") || starred != (original.first?.starred ?? false)
            || !heardInput.isEmpty || heardForms != saved
    }
    var validationMessage: String? {
        guard isDirty else { return nil }
        if Self.normalized(written) == nil { return FileVocabulary.validationMessage(heard: "x", written: written) }
        return effectiveHeardForms.lazy.compactMap { FileVocabulary.validationMessage(heard: $0, written: self.written) }.first
    }
    /// Not a blocker: the rule saves as written, the user just learns it will rewrite an everyday word.
    var everydayWarning: String? {
        effectiveHeardForms.lazy.compactMap { OrdinaryWords.warning(heard: $0, written: self.written) }.first
    }
    var canSave: Bool { !loadFailed && isDirty && validationMessage == nil }

    init(store: FileVocabulary) {
        self.store = store
        reload()
    }

    func reload() {
        guard !isDirty else { return }
        do {
            items = try store.allRules()
            loadFailed = false
            error = nil
            if !original.isEmpty {
                let keys = Set(original.map { FileVocabulary.heardKey($0.heard) })
                let match = items.first { keys.contains(FileVocabulary.heardKey($0.heard)) }
                setDraft(match.map { found in items.filter { $0.written == found.written } } ?? [], editing: isEditing && match != nil)
            }
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
    }

    /// Opens a saved word in the sheet.
    func select(_ word: SpellingWord) {
        guard !isDirty, !loadFailed else { return }
        setDraft(word.rules, editing: true)
        error = nil
    }

    func newSpelling() {
        guard !isDirty, !loadFailed else { return }
        setDraft([], editing: true)
        error = nil
    }

    /// Adds what is typed as a heard form. Blank and repeated phrases are ignored.
    func commitHeardInput() {
        guard let typed = Self.normalized(heardInput) else { heardInput = ""; return }
        if !heardForms.contains(where: { Self.sameForm($0, typed) }) { heardForms.append(typed) }
        heardInput = ""
    }

    func removeHeardForm(_ form: String) { heardForms.removeAll { $0 == form } }

    /// Closes the sheet and drops the draft.
    func cancel() {
        setDraft(original, editing: false)
        if !loadFailed { error = nil }
    }

    func save() {
        guard canSave else { return }
        let name = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = effectiveHeardForms.map { DictionaryRule(heard: $0, written: name, starred: starred) }
        do {
            try store.saveWord(original: original, rules: rules)
            setDraft(rules, editing: false)
            reload()
            onLibraryChanged()
        } catch { self.error = error.localizedDescription }
    }

    func delete() {
        guard !isDirty, !loadFailed, !original.isEmpty else { return }
        do {
            try store.removeAll(original)
            setDraft([], editing: false)
            reload()
            onLibraryChanged()
        } catch { self.error = error.localizedDescription }
    }

    /// The star beside a word: favour it while recognising. Saves straight away, so it waits for a clean page.
    func toggleStar(_ word: SpellingWord) {
        guard !isDirty, !loadFailed else { return }
        do {
            try store.saveWord(original: word.rules, rules: word.rules.map { DictionaryRule(heard: $0.heard, written: $0.written, starred: !word.starred) })
            error = nil
            reload()
            onLibraryChanged()
        } catch { self.error = error.localizedDescription }
    }

    func draftSnapshot() -> DraftRecovery.Draft? {
        guard isDirty else { return nil }
        return DraftRecovery.Draft(kind: .spelling, heardForms: heardForms, heardInput: heardInput, written: written, starred: starred)
    }

    /// Reopens a recovered draft as a new word, so Save adds it and Discard drops it.
    func restore(_ draft: DraftRecovery.Draft) {
        setDraft([], editing: true)
        heardForms = draft.heardForms
        heardInput = draft.heardInput
        written = draft.written
        starred = draft.starred
    }

    private func setDraft(_ rules: [DictionaryRule], editing: Bool) {
        original = rules
        isEditing = editing
        heardForms = rules.map(\.heard)
        heardInput = ""
        written = rules.first?.written ?? ""
        starred = rules.first?.starred ?? false
    }

    private static func normalized(_ text: String) -> String? {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func sameForm(_ a: String, _ b: String) -> Bool {
        FileVocabulary.heardKey(a) == FileVocabulary.heardKey(b)
    }
}

/// One saved spelling and the heard forms that lead to it.
struct SpellingWord: Identifiable, Equatable {
    let written: String
    let rules: [DictionaryRule]
    var id: String { written }
    var heardForms: [String] { rules.map(\.heard) }
    /// Favoured while recognising. A word counts as favoured only when all its rules are.
    var starred: Bool { !rules.isEmpty && rules.allSatisfy(\.starred) }
    /// Everyday-word warning for the first heard form that needs one.
    var warning: String? { rules.lazy.compactMap { OrdinaryWords.warning(for: $0) }.first }
    var hasEverydayPhrase: Bool { rules.contains { OrdinaryWords.warning(for: $0) != nil && $0.heard.contains(where: \.isWhitespace) } }
}
