import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SavedSpellingTests {
    @Test(arguments: [("", "Mouthtype"), ("  \n", "Mouthtype"), ("mouth type", ""), ("mouth type", "  \n")])
    func blankRulesNeverModifyTheLibrary(pair: (String, String)) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.json")
        let store = FileVocabulary(url: url)
        try store.save(heard: "mouth type", written: "Mouthtype")
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try store.save(heard: pair.0, written: pair.1) }
        #expect(try Data(contentsOf: url) == before)
    }
    private func library() throws -> (URL, FileVocabulary) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, FileVocabulary(url: directory.appendingPathComponent("dictionary.json")))
    }

    @Test func renameIsOneEditAndKeepsFlagsAndUnknownFields() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"[{"heard":"mouth type","written":"Mouthtype","starred":true,"note":"keep me"},{"heard":"orca","written":"Orca"}]"#.utf8).write(to: store.url)
        let original = try #require(store.allRules().first)
        try store.save(original: original, rule: DictionaryRule(heard: "  mouth   typing ", written: " Mouthtype ", starred: original.starred))
        #expect(try store.allRules() == [DictionaryRule(heard: "mouth typing", written: "Mouthtype", starred: true), DictionaryRule(heard: "orca", written: "Orca")])
        #expect(try String(contentsOf: store.url, encoding: .utf8).contains("keep me"))
    }

    @Test func duplicatesAndStaleEditsCannotOverwriteOtherRules() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        let original = try #require(store.allRules().first)
        let before = try Data(contentsOf: store.url)
        #expect(throws: FileVocabulary.WriteError.self) {
            try store.save(original: nil, rule: DictionaryRule(heard: "MOUTH  TYPE", written: "Other"))
        }
        #expect(try Data(contentsOf: store.url) == before)
        try store.save(heard: "mouth type", written: "Changed externally")
        let changed = try Data(contentsOf: store.url)
        #expect(throws: FileVocabulary.WriteError.changed) { try store.save(original: original, rule: DictionaryRule(heard: "mouth type", written: "Draft")) }
        #expect(throws: FileVocabulary.WriteError.changed) { try store.remove(original) }
        #expect(try Data(contentsOf: store.url) == changed)
    }

    @Test func renameCannotCollideAndDeleteKeepsOtherRules() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        try store.save(heard: "orca", written: "Orca")
        let original = try #require(store.allRules().first)
        let before = try Data(contentsOf: store.url)
        #expect(throws: FileVocabulary.WriteError.self) { try store.save(original: original, rule: DictionaryRule(heard: "ORCA", written: "Orca")) }
        #expect(try Data(contentsOf: store.url) == before)
        try store.remove(original)
        #expect(try store.allRules() == [DictionaryRule(heard: "orca", written: "Orca")])
    }

    @Test(arguments: ["[broken", #"[{"heard":"x","written":"X"},{"heard":"X","written":"Y"}]"#, #"[{"heard":"x","written":"X","starred":"yes"}]"#])
    func malformedOrAmbiguousLibrariesCannotBeManaged(text: String) throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(text.utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.allRules() }
        #expect(throws: (any Error).self) { try store.save(original: nil, rule: DictionaryRule(heard: "new", written: "New")) }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == text)
    }

    @Test func invalidNewEntriesNeverCreateAFile() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        for heard in ["", String(repeating: "x", count: 129)] {
            #expect(throws: FileVocabulary.WriteError.self) { try store.save(original: nil, rule: DictionaryRule(heard: heard, written: "X")) }
        }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

}
