import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct DraftRecoveryTests {
    private func makeRecovery() -> DraftRecovery {
        DraftRecovery(directory: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func aSavedDraftComesBackOnceAndTheFileIsRemoved() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let draft = DraftRecovery.Draft(kind: .phrase, trigger: "sig", expansion: "Best,\nScott")
        let url = try recovery.save(draft)
        #expect(url.lastPathComponent.hasPrefix("phrase-") && url.pathExtension == "json")
        #expect(recovery.take(.spelling) == nil)
        #expect(recovery.take(.phrase) == draft)
        #expect(recovery.take(.phrase) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theNewestDraftWins() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .phrase, trigger: "old", expansion: "x"), at: Date(timeIntervalSince1970: 1_000))
        try recovery.save(.init(kind: .phrase, trigger: "new", expansion: "y"), at: Date(timeIntervalSince1970: 2_000))
        #expect(recovery.take(.phrase)?.trigger == "new")
        #expect(recovery.take(.phrase) == nil)
    }
}

@MainActor @Suite struct DraftRecoveryEditorTests {
    @Test func aDirtyPhraseEditorRoundTripsThroughARecoveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DraftRecovery(directory: directory.appendingPathComponent("drafts"))
        let file = FilePhrases(url: directory.appendingPathComponent("phrases.json"))
        let before = PhraseEditor(store: file)
        before.trigger = "addr"
        before.expansion = "1 Main St"
        #expect(recovery.saveDrafts(spellings: nil, phrases: before).count == 1)

        let after = PhraseEditor(store: file)
        recovery.restoreDrafts(spellings: nil, phrases: after)
        #expect(after.isDirty && after.trigger == "addr" && after.expansion == "1 Main St")
        #expect(recovery.take(.phrase) == nil)
    }

    @Test func aDirtySpellingEditorRoundTripsThroughARecoveryFile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DraftRecovery(directory: directory.appendingPathComponent("drafts"))
        let vocabulary = FileVocabulary(url: directory.appendingPathComponent("dictionary.json"))
        let before = SpellingEditor(store: vocabulary)
        before.restore(.init(kind: .spelling, heardForms: ["kuber nettys"], heardInput: "kube", written: "Kubernetes", starred: true))
        #expect(recovery.saveDrafts(spellings: before, phrases: nil).count == 1)

        let after = SpellingEditor(store: vocabulary)
        recovery.restoreDrafts(spellings: after, phrases: nil)
        #expect(after.isDirty && after.isEditing)
        #expect(after.written == "Kubernetes" && after.starred && after.heardForms == ["kuber nettys"] && after.heardInput == "kube")
    }

    @Test func aCleanEditorWritesNothing() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = PhraseEditor(store: FilePhrases(url: directory.appendingPathComponent("phrases.json")))
        #expect(DraftRecovery(directory: directory.appendingPathComponent("drafts")).saveDrafts(spellings: nil, phrases: editor).isEmpty)
    }
}
