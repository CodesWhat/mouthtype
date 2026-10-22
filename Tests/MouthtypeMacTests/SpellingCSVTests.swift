import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct SpellingCSVTests {
    private func library() throws -> (URL, FileVocabulary) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, FileVocabulary(url: dir.appendingPathComponent("dictionary.json")))
    }

    @Test func previewThenExplicitImportPreservesExistingFields() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = "[{\"heard\":\"mouth type\",\"written\":\"Mouthtype\",\"starred\":true,\"note\":\"keep me\"}]"
        try Data(original.utf8).write(to: store.url)
        let preview = try store.previewImport(Data("heard,written\r\nshawn,Sean\r\nMOUTH   TYPE,Mouthtype\r\nshawn,Sean\r\n".utf8))
        #expect(preview.canImport)
        #expect(preview.rows.map(\.status) == [.add, .existing, .duplicate])
        #expect(try String(contentsOf: store.url, encoding: .utf8) == original)
        try store.importSpellings(preview)
        #expect(try store.allRules() == [DictionaryRule(heard: "mouth type", written: "Mouthtype", starred: true), DictionaryRule(heard: "shawn", written: "Sean")])
        let saved = try String(contentsOf: store.url, encoding: .utf8)
        #expect(saved.contains("keep me"))
    }

    @Test func namesAndQuotedAliasesNormalizeWithoutGuessing() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try store.previewImport(Data("\u{feff}name\nSean\nYakback\n".utf8))
        #expect(names.additions == [DictionaryRule(heard: "Sean", written: "Sean"), DictionaryRule(heard: "Yakback", written: "Yakback")])
        let aliases = try store.previewImport(Data("written,heard\n\"Acme, Inc.\",\" acme   incorporated \"\n\"Say \"\"hello\"\"\",greeting\n\"first\nsecond\",two lines\n".utf8))
        #expect(aliases.canImport)
        #expect(aliases.additions.map(\.written) == ["Acme, Inc.", "Say \"hello\"", "first\nsecond"])
        #expect(aliases.additions.first?.heard == "acme incorporated")
    }

    @Test func invalidRowsAndConflictsBlockTheEntireImport() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let original = try Data(contentsOf: store.url)
        for csv in [
            "heard,written\nnew,New\nSHAWN,Shaun", "heard,written\nnew,New\nNEW,Other", "heard,written\nnew,New\n,Blank", "heard,written\nnew,New\n" + String(repeating: "x", count: 129) + ",Long",
        ] {
            let preview = try store.previewImport(Data(csv.utf8))
            #expect(!preview.canImport)
            #expect(preview.rows.contains { if case .invalid = $0.status { true } else { false } })
            #expect(throws: (any Error).self) { try store.importSpellings(preview) }
            #expect(try Data(contentsOf: store.url) == original)
        }
    }

    @Test func malformedCSVAndUnsupportedHeadersAreRejected() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        for csv in [
            "", "word,alias\na,b", "heard,written,extra\na,b,c", "heard,heard\na,b", "heard,written\n\"unfinished,b", "heard,written\na,\"b\"junk", "heard,written\na,b,c", "heard,written\nqu\"ote,b",
            "heard,written\nonly-one", "name\nSea\u{0}n", "name\n" + Array(repeating: "Sean", count: 5001).joined(separator: "\n"),
        ] {
            let preview = try store.previewImport(Data(csv.utf8))
            #expect(!preview.canImport)
            #expect(preview.problem != nil || preview.rows.contains { if case .invalid = $0.status { true } else { false } })
        }
        #expect(try store.previewImport(Data([0xff])).problem != nil)
        #expect(try store.previewImport(Data(repeating: 97, count: SpellingCSV.maximumBytes + 1)).problem != nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func confirmationRejectsChangedLibraryIncludingUnknownFields() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = try store.previewImport(Data("name\nSean".utf8))
        try Data("[]\n".utf8).write(to: store.url)
        #expect(throws: FileVocabulary.WriteError.changed) { try store.importSpellings(preview) }
        try Data("[{\"heard\":\"a\",\"written\":\"A\",\"note\":1}]".utf8).write(to: store.url)
        let next = try store.previewImport(Data("name\nSean".utf8))
        let outside = Data("[{\"heard\":\"a\",\"written\":\"A\",\"note\":2}]".utf8)
        try outside.write(to: store.url)
        #expect(throws: FileVocabulary.WriteError.changed) { try store.importSpellings(next) }
        #expect(try Data(contentsOf: store.url) == outside)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.previewImport(Data("name\nSean".utf8)) }
    }
}

@MainActor @Suite struct SpellingImportEditorTests {
    @Test func selectionReadsOnlyTheChosenFileAndShowsReadFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let editor = SpellingEditor(store: store)
        let csv = dir.appendingPathComponent("names.csv")
        editor.previewImport(fileURL: csv)
        #expect(editor.showingImport && editor.importError != nil && !editor.canImport)
        editor.cancelImport()
        try Data("name\nSean".utf8).write(to: csv)
        editor.previewImport(fileURL: csv)
        #expect(editor.canImport && editor.importFileName == "names.csv")
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func previewCancelAndConfirmAreExplicitAndPreserveDrafts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let editor = SpellingEditor(store: store)
        editor.heardInput = "unsaved"
        editor.written = "Draft"
        editor.previewImport(data: Data("name\nSean".utf8), fileName: "names.csv")
        #expect(editor.importPreview == nil && editor.isDirty && !editor.showingImport)
        editor.cancel()
        editor.previewImport(data: Data("name\nSean".utf8), fileName: "names.csv")
        #expect(editor.showingImport && editor.canImport && editor.importFileName == "names.csv")
        #expect(try store.allRules().isEmpty)
        editor.cancelImport()
        #expect(!editor.showingImport && editor.importPreview == nil && !editor.canImport)
        editor.previewImport(data: Data("name\nSean".utf8), fileName: "names.csv")
        editor.heardInput = "new draft"
        editor.confirmImport()
        #expect(editor.isDirty && !editor.canImport)
        #expect(try store.allRules().isEmpty)
        editor.cancel()
        editor.confirmImport()
        #expect(!editor.showingImport && editor.items.map(\.written) == ["Sean"])
        #expect(editor.importMessage == "Imported 1 spelling.")
    }

    @Test func staleOrMalformedImportsStayOpenWithoutWriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let editor = SpellingEditor(store: store)
        editor.previewImport(data: Data("name\nSean".utf8), fileName: "names.csv")
        try store.save(heard: "other", written: "Other")
        editor.confirmImport()
        #expect(editor.showingImport && editor.importError != nil && !editor.canImport)
        #expect(try store.allRules().map(\.heard) == ["other"])
        editor.cancelImport()
        editor.previewImport(data: Data("name\n".utf8), fileName: "empty.csv")
        #expect(editor.showingImport && !editor.canImport && editor.importPreview?.problem != nil)
        editor.confirmImport()
        #expect(try store.allRules().count == 1)
    }
}
