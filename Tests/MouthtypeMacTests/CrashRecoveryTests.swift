import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
private final class StubEngine: DictationEngine {
    var readiness = EngineReadiness.ready
    var text = "Hello from the crash."
    var error: Error?
    private(set) var calls = 0

    func transcribe(samples: [Float]) async throws -> Transcription {
        calls += 1
        if let error { throw error }
        return Transcription(
            text: text, words: [WordTiming(word: "Hello", start: 0.1, end: 0.4, confidence: 0.9)],
            processingSeconds: 0.1, engineID: "stub"
        )
    }
}

@MainActor
private final class StubCards: DictationCards {
    var presented: [DeliveryCard] = []
    var actions: [CardAction: @MainActor () -> Void] = [:]
    var onUndo: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?

    func present(_ card: DeliveryCard, actions: [CardAction: @MainActor () -> Void]) {
        presented.append(card)
        self.actions = actions
    }

    func dismiss() { actions = [:] }
}

@MainActor
private final class StubPill: DictationPill {
    var messages: [PillMessage] = []
    func showRecording() {}
    func showHandsFree() {}
    func showHandsFreeNotice(_ text: String, duration: TimeInterval) {}
    func showProcessing() {}
    func showMessage(_ message: PillMessage, duration: TimeInterval) { messages.append(message) }
    func hide() {}
}

@MainActor
private struct Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-crash-\(UUID().uuidString)")
    let store: TranscriptStore
    let archive: AudioArchive
    let engine = StubEngine()
    let cards = StubCards()
    let pill = StubPill()
    let recovery: CrashRecovery
    let now = FakeClock.wall

    init(appStyles: @escaping @Sendable () -> AppCleanupStyles = { AppCleanupStyles() }) throws {
        store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        archive = AudioArchive(supportDirectory: dir)
        let clock = FakeClock(start: 1)
        var pipeline = DictationPipeline(store: TranscriptStoreWriter(store: store), archive: archive, engine: engine, clock: clock)
        pipeline.settings = { CleanupSettings() }
        pipeline.appStyles = appStyles
        recovery = CrashRecovery(
            store: store, archive: archive, pipeline: pipeline, cards: cards, pill: pill, clock: clock, launchedAt: FakeClock.wall
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    /// A row `ago` seconds old whose audio is a second of tone, archived or only in progress.
    @discardableResult
    func seed(ago: TimeInterval, partial: Bool = false, audio: Bool = true) throws -> String {
        let id = UUID().uuidString
        try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-ago)))
        guard audio else { return id }
        let tone = (0..<16_000).map { 0.3 * sin(Float($0) * 0.2) }
        if partial {
            try archive.appendPartial(samples: tone, id: id)
        } else {
            let entry = try archive.write(samples: tone, id: id)
            try store.recordCapture(id, CaptureRecord(audioMs: 1000, audioPath: entry.url.path))
        }
        return id
    }
}

@MainActor
@Suite struct CrashRecoveryTests {
    @Test func recoveryWithoutCapturedAppUsesGlobalTone() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: StylePreset.veryCasual.options)
        let configured = styles
        let rig = try Rig(appStyles: { configured })
        defer { rig.cleanUp() }
        try rig.seed(ago: 90)
        await rig.recovery.offerIfNeeded()
        await rig.recovery.recover()
        #expect(rig.cards.presented.last?.transcript == "Hello from the crash.")
    }

    @Test func recoveryDoesNotRunOverAnActiveDictation() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.seed(ago: 50)
        await rig.recovery.offerIfNeeded()
        rig.recovery.canRecover = { false }
        await rig.recovery.recover()
        #expect(rig.engine.calls == 0 && rig.recovery.offered != nil)
        #expect(rig.cards.actions[.recover] != nil)
        rig.recovery.canRecover = { true }
        await rig.recovery.recover()
        #expect(rig.engine.calls == 1 && rig.cards.presented.last?.kind == .recovered)
    }

    @Test func savedRecordingsMenuListsOlderAudioAndRespectsBusyState() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let older = try rig.seed(ago: 300)
        let newest = try rig.seed(ago: 50)
        await rig.recovery.offerIfNeeded()
        let menu = SavedRecordingsMenuSection(recovery: rig.recovery, canRecover: { true })
        let entries = try #require(menu.items.first?.submenu?.items)
        #expect(menu.items.first?.submenu?.autoenablesItems == false)
        #expect(entries.count == 2)
        #expect((entries[0].representedObject as? RecoverableDictation)?.id == newest)
        #expect((entries[1].representedObject as? RecoverableDictation)?.id == older)
        #expect(entries.allSatisfy { $0.isEnabled && $0.action != nil })
        let busy = SavedRecordingsMenuSection(recovery: rig.recovery, canRecover: { false })
        #expect(busy.items.first?.submenu?.items.allSatisfy { !$0.isEnabled } == true)
    }

    @Test(arguments: [false, true]) func failedRecoveryCanBeRetriedFromTheSameOffer(partial: Bool) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.seed(ago: 50, partial: partial)
        rig.engine.error = CocoaError(.fileReadUnknown)
        await rig.recovery.offerIfNeeded()
        await rig.recovery.recover()
        #expect(rig.cards.actions[.recover] != nil)
        rig.engine.error = nil
        await rig.recovery.recover()
        #expect(rig.engine.calls == 2)
        #expect(rig.cards.presented.last?.kind == .recovered)
    }

    @Test func theNewestIsOfferedWithItsLengthAndAgeAndTheOlderOnesCounted() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.seed(ago: 4_000)
        try rig.seed(ago: 3_000)
        let newest = try rig.seed(ago: 125)
        try rig.seed(ago: 60, audio: false)

        let scan = await rig.recovery.offerIfNeeded()
        #expect(scan?.newest?.id == newest && scan?.olderCount == 2 && scan?.lostCount == 1)
        let card = try #require(rig.cards.presented.last)
        #expect(card == .recoverOffer(seconds: 1, ago: 125, older: 2))
        #expect(card.header == "Recover your last dictation?\n1 second, 2 minutes ago\nand 2 older ones in Saved Recordings")
        #expect(card.actions == [.recover, .discard])
    }

    @Test func recoverTranscribesCleansAndShowsACopyCardWithoutPasting() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let id = try rig.seed(ago: 90)
        await rig.recovery.offerIfNeeded()
        let recover = try #require(rig.cards.actions[.recover])
        recover()
        for _ in 0..<400 where rig.cards.presented.last?.kind != .recovered { try await Task.sleep(for: .milliseconds(10)) }

        let result = try #require(rig.cards.presented.last)
        #expect(result.kind == .recovered && result.transcript == "Hello from the crash." && result.actions == [.copy])
        #expect(rig.engine.calls == 1)
        let row = try #require(try rig.store.dictation(id: id))
        #expect(row.status == .inserted && row.finalText == "Hello from the crash." && row.insertMethod == "none")
        #expect(row.rawText == "Hello from the crash.")
    }

    @Test func aSecondLaunchOffersNothingAfterARecoveryOrADiscard() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.seed(ago: 90)
        await rig.recovery.offerIfNeeded()
        await rig.recovery.recover()
        let again = await rig.recovery.offerIfNeeded()
        #expect(again?.newest == nil)

        let other = try rig.seed(ago: 30)
        await rig.recovery.offerIfNeeded()
        await rig.recovery.discard()
        #expect(try rig.store.dictation(id: other)?.status == .cancelled)
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: other).path))
        #expect(await rig.recovery.offerIfNeeded()?.newest == nil)
    }

    @Test func aRecordingKnownOnlyByItsInProgressCopyGetsItsWavAndCaptureFields() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let id = try rig.seed(ago: 90, partial: true)
        let scan = await rig.recovery.offerIfNeeded()
        #expect(scan?.newest?.isPartial == true)
        await rig.recovery.recover()
        let row = try #require(try rig.store.dictation(id: id))
        #expect(row.status == .inserted && row.audioPath == rig.archive.url(for: id).path)
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: id).path))
        #expect(!FileManager.default.fileExists(atPath: rig.archive.partialURL(for: id).path))
    }

    @Test func audioWithNoSpeechSaysSoAndShowsNoCard() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let id = UUID().uuidString
        try rig.store.begin(DictationStart(id: id, startedAt: rig.now.addingTimeInterval(-50)))
        let entry = try rig.archive.write(samples: [Float](repeating: 0, count: 16_000), id: id)
        try rig.store.recordCapture(id, CaptureRecord(audioPath: entry.url.path))
        await rig.recovery.offerIfNeeded()
        await rig.recovery.recover()
        #expect(rig.pill.messages.first?.headline == "Nothing to recover")
        #expect(rig.cards.presented.count == 1 && rig.engine.calls == 0)
        #expect(try rig.store.dictation(id: id)?.status == .empty)
    }

    @Test func anEngineFailureLeavesTheRowEndedAndSaysSo() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let id = try rig.seed(ago: 50)
        rig.engine.error = CocoaError(.fileReadUnknown)
        await rig.recovery.offerIfNeeded()
        await rig.recovery.recover()
        #expect(rig.pill.messages.first?.headline == "Couldn't recover")
        let row = try #require(try rig.store.dictation(id: id))
        #expect(row.status == .failed && row.errorMessage == "interrupted")
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: id).path))
    }
}
