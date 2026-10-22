import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct SpellingTransferTests {
    private func library() throws -> (URL, FileVocabulary) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, FileVocabulary(url: dir.appendingPathComponent("dictionary.json")))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SpellingImport/\(name)")
        return try Data(contentsOf: url)
    }

    @Test func exportThenImportReproducesTheDictionary() throws {
        let (dir, source) = try library()
        let (otherDir, target) = try library()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let rules = [
            DictionaryRule(heard: "shawn", written: "Sean"),
            DictionaryRule(heard: "acme incorporated", written: "Acme, Inc."),
            DictionaryRule(heard: "say hello", written: "Say \"hello\""),
            DictionaryRule(heard: "two lines", written: "first\nsecond"),
            DictionaryRule(heard: "mouth type", written: "Mouthtype"),
        ]
        for rule in rules { try source.save(heard: rule.heard, written: rule.written) }
        let csv = SpellingCSV.export(try source.allRules())
        #expect(csv.hasPrefix("heard,written\n"))
        let preview = try target.previewImport(Data(csv.utf8))
        #expect(preview.canImport && preview.additions == rules)
        try target.importSpellings(preview)
        #expect(try target.allRules() == rules)
        #expect(SpellingCSV.export(try target.allRules()) == csv)
    }

    @Test func phraseExportQuotesMultilineExpansions() throws {
        let csv = SpellingCSV.export([Snippet(trigger: "my address", expansion: "1 Main St,\nTown"), Snippet(trigger: "sig", expansion: "Best, \"S\"")])
        #expect(csv == "trigger,expansion\nmy address,\"1 Main St,\nTown\"\nsig,\"Best, \"\"S\"\"\"\n")
        let records = try SpellingCSV.records(from: Data(csv.utf8))
        #expect(records.map(\.fields) == [["trigger", "expansion"], ["my address", "1 Main St,\nTown"], ["sig", "Best, \"S\""]])
    }

    @Test func wisprFlowCSVImportsWithoutOverwriting() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let preview = try store.previewImport(try fixture("wispr-flow-dictionary.csv"), source: .wispr)
        #expect(preview.canImport)
        #expect(preview.rows.map(\.status) == [.add, .existing, .add, .add])
        #expect(
            preview.additions == [
                DictionaryRule(heard: "Whisper Flow", written: "Wispr Flow"),
                DictionaryRule(heard: "Acme, Inc.", written: "Acme"),
                DictionaryRule(heard: "Kubernetes", written: "Kubernetes"),
            ])
        try store.importSpellings(preview)
        #expect(try store.allRules().first == DictionaryRule(heard: "shawn", written: "Sean"))
        #expect(try store.allRules().count == 4)
    }

    @Test func wisprFlowRowsWithTooManyColumnsBlockTheImport() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = try store.previewImport(Data("a,b,c\n".utf8), source: .wispr)
        #expect(!preview.canImport)
    }

    @Test func voiceInkJSONImportsVocabularyAndReplacementSources() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let preview = try store.previewImport(try fixture("voiceink-dictionary.json"), source: .voiceInk)
        #expect(preview.canImport)
        #expect(preview.rows.map(\.status) == [.add, .add, .add, .add, .existing])
        #expect(
            preview.additions == [
                DictionaryRule(heard: "Drydock", written: "Drydock"),
                DictionaryRule(heard: "Sockguard", written: "Sockguard"),
                DictionaryRule(heard: "dry doc", written: "Drydock"),
                DictionaryRule(heard: "dry dock", written: "Drydock"),
            ])
        try store.importSpellings(preview)
        #expect(try store.allRules().count == 5)
    }

    @Test func voiceInkConflictsAndForeignFilesAreRefused() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Shaun")
        let conflict = try store.previewImport(try fixture("voiceink-dictionary.json"), source: .voiceInk)
        #expect(!conflict.canImport)
        for text in ["{}", "[]", "not json", "{\"format\":\"other\",\"vocabulary\":[]}"] {
            let preview = try store.previewImport(Data(text.utf8), source: .voiceInk)
            #expect(preview.problem != nil && !preview.canImport)
        }
    }

    @Test @MainActor func editorExportsToAFileAndReportsTheCount() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let editor = SpellingEditor(store: store)
        let out = dir.appendingPathComponent("out.csv")
        editor.exportCSV(to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "heard,written\nshawn,Sean\n")
        #expect(editor.importMessage == "Exported 1 spelling.")
    }
}
