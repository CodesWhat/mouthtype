import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class SpellingEditor {
    private let store: FileVocabulary
    private(set) var items: [DictionaryRule] = []
    private(set) var original: DictionaryRule?
    var heard = ""
    var written = ""
    private(set) var error: String?
    private(set) var loadFailed = false
    private(set) var importPreview: SpellingImportPreview?
    private(set) var importFileName = ""
    private(set) var importError: String?
    private(set) var importMessage: String?
    var showingImport = false
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
            importMessage = "Imported \(count) spelling\(count == 1 ? "" : "s")."
        } catch FileVocabulary.WriteError.changed {
            importError = "The spelling library changed after this preview. Cancel and choose the CSV again."
        } catch { importError = error.localizedDescription }
    }

    var isDirty: Bool { heard != (original?.heard ?? "") || written != (original?.written ?? "") }
    var validationMessage: String? { isDirty ? FileVocabulary.validationMessage(heard: heard, written: written) : nil }
    /// Not a blocker: the rule saves as written, the user just learns it will rewrite an everyday word.
    var everydayWarning: String? { OrdinaryWords.warning(heard: heard, written: written) }
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
            if let original { setDraft(items.first { FileVocabulary.heardKey($0.heard) == FileVocabulary.heardKey(original.heard) }) }
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
    }

    func select(_ rule: DictionaryRule) {
        guard !isDirty else { return }
        setDraft(rule)
        if !loadFailed { error = nil }
    }

    func newSpelling() {
        guard !isDirty, !loadFailed else { return }
        setDraft(nil)
        error = nil
    }

    func cancel() {
        setDraft(original)
        if !loadFailed { error = nil }
    }

    func save() {
        guard canSave else { return }
        do {
            let rule = DictionaryRule(heard: heard.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                written: written.trimmingCharacters(in: .whitespacesAndNewlines), starred: original?.starred ?? false)
            try store.save(original: original, rule: rule)
            setDraft(rule)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func delete() {
        guard !isDirty, !loadFailed, let original else { return }
        do {
            try store.remove(original)
            setDraft(nil)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func setDraft(_ rule: DictionaryRule?) {
        original = rule
        heard = rule?.heard ?? ""
        written = rule?.written ?? ""
    }
}
