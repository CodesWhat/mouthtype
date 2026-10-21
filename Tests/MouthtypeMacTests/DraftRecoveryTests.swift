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

@MainActor
private final class DraftStubCards: DictationCards {
    var presented: [DeliveryCard] = []
    var actions: [CardAction: @MainActor () -> Void] = [:]
    var onUndo: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?
    var onCardChange: (@MainActor (DeliveryCard?) -> Void)?

    func present(_ card: DeliveryCard, actions: [CardAction: @MainActor () -> Void]) {
        presented.append(card)
        self.actions = actions
    }

    func dismiss() { actions = [:] }
}

@MainActor @Suite struct DraftOfferTests {
    private func makeRecovery() -> DraftRecovery {
        DraftRecovery(directory: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true))
    }

    private func names(_ recovery: DraftRecovery) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: recovery.directory.path)) ?? []).sorted()
    }

    @Test func recoverShowsTheTextThenMovesTheFileToRecovered() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .phrase, trigger: "sig", expansion: "Best,\nScott"), at: Date(timeIntervalSince1970: 1))
        let cards = DraftStubCards()
        let offer = DraftOffer(recovery: recovery, cards: cards)
        #expect(offer.offerIfNeeded() == 1)
        #expect(cards.presented.last?.kind == .recoverOffer)
        #expect(names(recovery).count == 1, "nothing is deleted before the user answers")
        cards.actions[.recover]?()
        #expect(cards.presented.last?.kind == .recovered)
        #expect(cards.presented.last?.transcript?.contains("Best,\nScott") == true)
        #expect(names(recovery) == ["recovered"])
    }

    @Test func discardRemovesTheFileWithoutShowingText() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .spelling, heardInput: "kube", written: "Kubernetes"), at: Date(timeIntervalSince1970: 1))
        let cards = DraftStubCards()
        let offer = DraftOffer(recovery: recovery, cards: cards)
        offer.offerIfNeeded()
        cards.actions[.discard]?()
        #expect(cards.presented.count == 1)
        #expect(names(recovery).isEmpty)
    }

    @Test func aSecondOfferInTheSameLaunchOrAfterRecoverNeverRepeatsADraft() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .phrase, trigger: "a", expansion: "b"), at: Date(timeIntervalSince1970: 1))
        let cards = DraftStubCards()
        let offer = DraftOffer(recovery: recovery, cards: cards)
        #expect(offer.offerIfNeeded() == 1)
        #expect(offer.offerIfNeeded() == 0)
        let recover = cards.actions[.recover]
        recover?()
        recover?()
        #expect(cards.presented.filter { $0.kind == .recovered }.count == 1)
        #expect(DraftOffer(recovery: recovery, cards: cards).offerIfNeeded() == 0)
    }

    @Test func severalDraftsShareOneCardOldestFirst() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try recovery.save(.init(kind: .phrase, trigger: "second", expansion: "x"), at: Date(timeIntervalSince1970: 2))
        try recovery.save(.init(kind: .spelling, written: "First"), at: Date(timeIntervalSince1970: 1))
        let cards = DraftStubCards()
        let offer = DraftOffer(recovery: recovery, cards: cards)
        #expect(offer.offerIfNeeded() == 2)
        cards.actions[.recover]?()
        let text = cards.presented.last?.transcript ?? ""
        #expect(text.contains("second") && text.contains("First"))
        #expect(names(recovery) == ["recovered"])
    }

    @Test func corruptAndPartialFilesAreMovedAsideNotCrashedOn() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: recovery.directory.appendingPathComponent("phrase-1.json"))
        try Data("{\"trigger\":\"x\"}".utf8).write(to: recovery.directory.appendingPathComponent("phrase-2.json"))
        try Data().write(to: recovery.directory.appendingPathComponent("spelling-3.json"))
        let found = recovery.pending()
        #expect(found.drafts.isEmpty)
        #expect(found.setAside.count == 3)
        #expect(names(recovery) == ["corrupt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: recovery.directory.appendingPathComponent("corrupt").path).count == 3)
        #expect(DraftOffer(recovery: recovery, cards: DraftStubCards()).offerIfNeeded() == 0)
    }

    @Test func aDraftFromBeforeTheSchemaWasVersionedStillReads() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
        let old = "{\"kind\":\"phrase\",\"trigger\":\"addr\",\"expansion\":\"1 Main St\"}"
        try Data(old.utf8).write(to: recovery.directory.appendingPathComponent("phrase-1.json"))
        let found = recovery.pending()
        #expect(found.drafts.count == 1)
        #expect(found.drafts.first?.draft.version == 0)
        #expect(found.drafts.first?.draft.trigger == "addr" && found.drafts.first?.draft.starred == false)
    }

    @Test func aNewerSchemaIsLeftInPlaceAndABlankDraftIsDropped() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
        try Data("{\"version\":99,\"kind\":\"phrase\",\"trigger\":\"t\"}".utf8).write(to: recovery.directory.appendingPathComponent("phrase-1.json"))
        try Data("{\"version\":1,\"kind\":\"phrase\"}".utf8).write(to: recovery.directory.appendingPathComponent("phrase-2.json"))
        let found = recovery.pending()
        #expect(found.drafts.isEmpty && found.setAside.isEmpty)
        #expect(names(recovery) == ["phrase-1.json"])
    }

    @Test func aMissingDirectoryOffersNothing() {
        let recovery = makeRecovery()
        #expect(DraftOffer(recovery: recovery, cards: DraftStubCards()).offerIfNeeded() == 0)
        #expect(!FileManager.default.fileExists(atPath: recovery.directory.path))
    }

    @Test func recoveredDraftsAreKeptForAWeekThenPruned() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let folder = recovery.directory.appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("phrase-1.json"), fresh = folder.appendingPathComponent("phrase-2.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 86_400)], ofItemAtPath: fresh.path)
        _ = recovery.pending()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["phrase-2.json"])
    }

    @Test func aNewerSchemaWithAnUnknownKindIsLeftInPlaceNotMovedAside() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
        try Data("{\"version\":2,\"kind\":\"snippet\",\"body\":\"x\"}".utf8).write(to: recovery.directory.appendingPathComponent("snippet-1.json"))
        let found = recovery.pending()
        #expect(found.drafts.isEmpty && found.setAside.isEmpty)
        #expect(names(recovery) == ["snippet-1.json"])
    }

    @Test func draftsComeBackOldestSavedFirstAcrossKinds() throws {
        let recovery = makeRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        // Filename order would put phrase- before spelling-, whatever the dates.
        let newer = try recovery.save(.init(kind: .phrase, trigger: "newer", expansion: "x"), at: Date(timeIntervalSince1970: 2))
        let older = try recovery.save(.init(kind: .spelling, written: "older"), at: Date(timeIntervalSince1970: 1))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        #expect(recovery.pending().drafts.map(\.url.lastPathComponent) == [older.lastPathComponent, newer.lastPathComponent])
    }
}
