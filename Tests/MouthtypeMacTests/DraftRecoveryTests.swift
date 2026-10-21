import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct DraftRecoveryTests {
    private func makeRecovery() -> DraftRecovery {
        DraftRecovery(directory: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func aSavedDraftIsWrittenAsJSONAndNeverRemoved() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let draft = DraftRecovery.Draft(kind: .phrase, trigger: "sig", expansion: "Best,\nScott")
        let url = try recovery.save(draft, at: Date(timeIntervalSince1970: 1_000))
        #expect(url.lastPathComponent == "phrase-1000000.json")
        #expect(try JSONDecoder().decode(DraftRecovery.Draft.self, from: Data(contentsOf: url)) == draft)
    }

    @Test func anOlderDraftIsNotOverwritten() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .phrase, trigger: "old", expansion: "x"), at: Date(timeIntervalSince1970: 1_000))
        try recovery.save(.init(kind: .phrase, trigger: "new", expansion: "y"), at: Date(timeIntervalSince1970: 2_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: recovery.directory.path).count == 2)
    }
}

@MainActor @Suite struct DraftRecoveryEditorTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func dirtyPhraseAndSpellingEditorsEachWriteTheirDraft() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = DraftRecovery(directory: root.appendingPathComponent("drafts"))
        let phrases = PhraseEditor(store: FilePhrases(url: root.appendingPathComponent("phrases.json")))
        phrases.trigger = "addr"
        phrases.expansion = "1 Main St"
        let spellings = SpellingEditor(store: FileVocabulary(url: root.appendingPathComponent("dictionary.json")))
        spellings.written = "Kubernetes"
        spellings.heardInput = "kube"
        let urls = recovery.saveDrafts(spellings: spellings, phrases: phrases)
        #expect(urls.count == 2)
        let drafts = try urls.map { try JSONDecoder().decode(DraftRecovery.Draft.self, from: Data(contentsOf: $0)) }
        #expect(drafts.contains { $0.kind == .phrase && $0.trigger == "addr" && $0.expansion == "1 Main St" })
        #expect(drafts.contains { $0.kind == .spelling && $0.written == "Kubernetes" && $0.heardInput == "kube" })
    }

    @Test func aCleanEditorWritesNothing() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = PhraseEditor(store: FilePhrases(url: root.appendingPathComponent("phrases.json")))
        #expect(DraftRecovery(directory: root.appendingPathComponent("drafts")).saveDrafts(spellings: nil, phrases: editor).isEmpty)
    }
}
