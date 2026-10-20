import AppKit
import Foundation
import Observation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Observable final class RecoverGate { var open = true }

@MainActor @Suite struct HomeLogModelTests {
    private let base = Date(timeIntervalSince1970: 1_791_806_400)

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-home-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    @discardableResult
    private func dictate(_ store: TranscriptStore, minutes: Double, text: String, app: String? = nil, secure: Bool = false) throws -> String {
        let id = try store.begin(DictationStart(
            startedAt: base.addingTimeInterval(minutes * 60), target: DictationTarget(appName: app, isSecure: secure ? true : nil)))
        try store.recordInsertion(id, InsertionRecord(finalText: text))
        return id
    }

    private func recording(_ id: String, minutes: Double) -> RecoverableDictation {
        RecoverableDictation(id: id, startedAt: base.addingTimeInterval(minutes * 60),
                             audioURL: URL(fileURLWithPath: "/tmp/\(id).wav"), seconds: 4, isPartial: false)
    }

    @Test func takesAreNewestFirstAndSkipSecureAndBlankRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "first")
        try dictate(store, minutes: 3, text: "third", app: "Notes")
        try dictate(store, minutes: 2, text: "   ")
        try dictate(store, minutes: 4, text: "password", secure: true)
        try dictate(store, minutes: 5, text: "fifth")
        let model = HomeLogModel(store: store)
        await model.loadText()
        #expect(model.takes.map(\.text) == ["fifth", "third", "first"])
        #expect(model.takes[1].appName == "Notes")
        #expect(model.error == nil)
    }

    @Test func longTextIsKeptWhole() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = Array(repeating: "a long dictated sentence that keeps going", count: 40).joined(separator: " ")
        try dictate(store, minutes: 1, text: long)
        let model = HomeLogModel(store: store)
        await model.loadText()
        #expect(model.takes.first?.text == long)
    }

    @Test func logIsCappedAtTheLimit() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<(HomeLogModel.limit + 5) { try dictate(store, minutes: Double(index), text: "take \(index)") }
        let model = HomeLogModel(store: store)
        await model.loadText()
        #expect(model.takes.count == HomeLogModel.limit)
        #expect(model.takes.first?.text == "take \(HomeLogModel.limit + 4)")
    }

    @Test func missingStoreReportsUnavailable() async {
        let model = HomeLogModel(store: nil)
        await model.loadText()
        #expect(model.takes.isEmpty)
        #expect(model.error == "Recent dictations are unavailable.")
    }

    @Test func savedAudioJoinsItsTakeAndTextlessRecordingsBecomeTakes() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = try dictate(store, minutes: 1, text: "has audio")
        try dictate(store, minutes: 2, text: "no audio")
        let first = recording(kept, minutes: 1)
        let second = recording("lost-take", minutes: 3)
        let model = HomeLogModel(store: store, saved: { [first, second] in [first, second] })
        await model.reload()
        #expect(model.takes.map(\.text) == [nil, "no audio", "has audio"])
        #expect(model.takes[0].recoverable?.id == "lost-take")
        #expect(model.takes[1].recoverable == nil)
        #expect(model.takes[2].recoverable?.id == kept)
    }

    @Test func savedAudioFailureStillShowsTheText() async throws {
        struct Boom: Error {}
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "still here")
        let model = HomeLogModel(store: store, saved: { throw Boom() })
        await model.reload()
        #expect(model.takes.map(\.text) == ["still here"])
    }

    @Test func copyAndRecoverRouteToTheirActions() {
        var copied: [String] = []
        var recovered: [String] = []
        var allowed = true
        let model = HomeLogModel(canRecover: { allowed }, recover: { recovered.append($0.id) }, copy: { copied.append($0) })
        let withAudio = HomeTake(id: "a", startedAt: base, text: "hello there", appName: nil, recoverable: recording("a", minutes: 0))
        let textOnly = HomeTake(id: "b", startedAt: base, text: "text only", appName: nil, recoverable: nil)
        let audioOnly = HomeTake(id: "c", startedAt: base, text: nil, appName: nil, recoverable: recording("c", minutes: 0))
        model.copy(withAudio)
        model.copy(audioOnly)
        #expect(copied == ["hello there"] && model.lastCopiedID == "a")
        model.recover(withAudio)
        model.recover(textOnly)
        model.recover(audioOnly)
        #expect(recovered == ["a", "c"])
        allowed = false
        model.recover(withAudio)
        #expect(recovered == ["a", "c"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func finishedTakesAppearWithoutReloading() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "first")
        let model = HomeLogModel(store: store)
        await waitUntil { model.takes.map(\.text) == ["first"] }
        #expect(model.takes.map(\.text) == ["first"])
        try dictate(store, minutes: 2, text: "second")
        await waitUntil { model.takes.count == 2 }
        #expect(model.takes.map(\.text) == ["second", "first"])
    }

    @Test func observedChangesRefetchSavedAudio() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try dictate(store, minutes: 1, text: "kept")
        let audio = recording(id, minutes: 1)
        var audioSaved = false
        let model = HomeLogModel(store: store, saved: { audioSaved ? [audio] : [] })
        await waitUntil { model.takes.count == 1 }
        #expect(model.takes.first?.recoverable == nil)
        audioSaved = true
        try dictate(store, minutes: 2, text: "newer")
        await waitUntil { model.takes.first(where: { $0.id == id })?.recoverable != nil }
        #expect(model.takes.first(where: { $0.id == id })?.recoverable == audio)
    }

    @Test func recoverEnabledFollowsObservableState() async {
        let gate = RecoverGate()
        let model = HomeLogModel(canRecover: { gate.open })
        #expect(model.recoverEnabled)
        gate.open = false
        await waitUntil { !model.recoverEnabled }
        #expect(!model.recoverEnabled)
        gate.open = true
        await waitUntil { model.recoverEnabled }
        #expect(model.recoverEnabled)
    }

    @Test func recoverEnabledRefreshesOnDemandForPlainState() {
        var allowed = false
        let model = HomeLogModel(canRecover: { allowed })
        #expect(!model.recoverEnabled)
        allowed = true
        model.refreshRecoverability()
        #expect(model.recoverEnabled)
    }

    @Test func swappingTheStoreRestartsTheObservation() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HomeLogModel()
        model.store = store
        try dictate(store, minutes: 1, text: "late arrival")
        await waitUntil { model.takes.count == 1 }
        #expect(model.takes.map(\.text) == ["late arrival"])
    }

    @Test func guardedCopyMarksTheClipboardConcealed() {
        let board = NSPasteboard(name: NSPasteboard.Name("mouthtype-home-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        HomeLogModel.guardedCopy("hello", to: SystemPasteboard(board))
        let types = Set((board.types ?? []).map(\.rawValue))
        #expect(board.string(forType: .string) == "hello")
        #expect(types.isSuperset(of: PasteboardSession.concealedMarkers))
    }

    @Test func observationStopsOnDeactivateAndRestartsFreshOnActivate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "first")
        let model = HomeLogModel(store: store, observing: false)
        #expect(model.takes.isEmpty && !model.isActive)
        model.activate()
        await waitUntil { model.takes.count == 1 }
        model.deactivate()
        try dictate(store, minutes: 2, text: "while closed")
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.takes.map(\.text) == ["first"])
        model.activate()
        await waitUntil { model.takes.count == 2 }
        #expect(model.takes.map(\.text) == ["while closed", "first"])
    }

    @Test func storeSwapWhileInactiveDoesNotObserve() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "first")
        let model = HomeLogModel(observing: false)
        model.store = store
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.takes.isEmpty)
    }

    @Test func aStaleAudioScanNeverOverwritesANewerOne() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try dictate(store, minutes: 1, text: "kept")
        let audio = recording(id, minutes: 1)
        var calls = 0
        let model = HomeLogModel(store: store, saved: {
            calls += 1
            if calls == 1 { try await Task.sleep(for: .milliseconds(400)); return [] }
            return [audio]
        }, observing: false)
        await model.loadText()
        async let slow: Void = model.reload()
        try await Task.sleep(for: .milliseconds(100))
        await model.reload()
        #expect(model.takes.first?.recoverable == audio)
        await slow
        #expect(model.takes.first?.recoverable == audio)
    }

    @Test func finishedTakesGetRecoverFromTheirOwnAudio() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try dictate(store, minutes: 1, text: "kept")
        let audio = recording(id, minutes: 1)
        let model = HomeLogModel(store: store, observing: false)
        model.completedAudio = { rows in rows.contains { $0.id == id } ? [audio] : [] }
        await model.reload()
        #expect(model.takes.first?.recoverable == audio)
    }

    @Test func completedAudioFollowsEachRowsPathAndExpiry() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let tone = (0..<16_000).map { 0.3 * sin(Float($0) * 0.2) }
        let kept = try dictate(store, minutes: 1, text: "kept")
        let expired = try dictate(store, minutes: 2, text: "expired")
        let missing = try dictate(store, minutes: 3, text: "missing")
        _ = try dictate(store, minutes: 4, text: "no audio")
        for (id, expires) in [(kept, base.addingTimeInterval(9_000)), (expired, base.addingTimeInterval(-5))] {
            let entry = try archive.write(samples: tone, id: id)
            try store.recordCapture(id, CaptureRecord(audioMs: 1000, audioPath: entry.url.path, audioExpiresAt: expires))
        }
        try store.recordCapture(missing, CaptureRecord(audioMs: 1000, audioPath: dir.appendingPathComponent("gone.wav").path))
        let found = DictationRecovery.completed(rows: try store.recentTakes(limit: 10), now: base)
        #expect(found.map(\.id) == [kept] && found.first?.isCompleted == true)
    }
}
