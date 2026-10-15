import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@Suite struct FilePhrasesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-phrases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func missingLibraryStartsEmptyWithoutCreatingExamples() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phrases.json")
        #expect(try FilePhrases(url: url).all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func saveRenameAndDeleteSurviveReloadAndPreserveExactText() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phrases.json")
        let store = FilePhrases(url: url)
        let original = Snippet(trigger: "my work email", expansion: "name@example.com")
        try store.save(original: nil, phrase: original)
        #expect(try FilePhrases(url: url).all() == [original])
        let edited = Snippet(trigger: "my signature", expansion: "  Best,\n\tScott  ")
        try store.save(original: original, phrase: edited)
        #expect(try FilePhrases(url: url).all() == [edited])
        try store.remove(edited)
        #expect(try FilePhrases(url: url).all().isEmpty)
    }

    @Test func duplicatesUseTheMatchersCaseAndWhitespaceRules() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phrases.json")
        let store = FilePhrases(url: url)
        try store.save(original: nil, phrase: Snippet(trigger: "my email", expansion: "first@example.com"))
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) {
            try store.save(original: nil, phrase: Snippet(trigger: " MY\t EMAIL ", expansion: "second@example.com"))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test(arguments: [Snippet(trigger: " \n", expansion: "text"), Snippet(trigger: "phrase", expansion: " \n")])
    func emptyValuesAreRejected(phrase: Snippet) throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePhrases(url: directory.appendingPathComponent("phrases.json"))
        #expect(throws: (any Error).self) { try store.save(original: nil, phrase: phrase) }
        #expect(store.snippets().isEmpty)
    }

    @Test func malformedFilesKeepLastGoodPhrasesAndCannotBeOverwritten() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phrases.json")
        let store = FilePhrases(url: url)
        let saved = Snippet(trigger: "my email", expansion: "first@example.com")
        try store.save(original: nil, phrase: saved)
        try "broken JSON".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.all() }
        #expect(store.snippets() == [saved])
        #expect(throws: (any Error).self) { try store.save(original: saved, phrase: Snippet(trigger: "changed", expansion: "text")) }
        #expect(throws: (any Error).self) { try store.remove(saved) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken JSON")
    }

    @Test func externalEditsReloadAndStaleEditsCannotOverwriteThem() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phrases.json")
        let store = FilePhrases(url: url)
        let original = Snippet(trigger: "my email", expansion: "first@example.com")
        let changed = Snippet(trigger: "my email", expansion: "changed@example.com")
        try store.save(original: nil, phrase: original)
        try FilePhrases(url: url).save(original: original, phrase: changed)
        #expect(store.snippets() == [changed])
        #expect(throws: (any Error).self) { try store.save(original: original, phrase: original) }
        #expect(throws: (any Error).self) { try store.remove(original) }
        #expect(try store.all() == [changed])
    }
}
