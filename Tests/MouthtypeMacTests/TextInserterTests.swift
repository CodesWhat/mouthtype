// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import ApplicationServices
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private func text(_ s: String) -> PasteboardRepresentation {
    PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(s.utf8))
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var contents = PasteboardSnapshot(items: [])
    var writes: [(text: String, markers: [String])] = []
    var snapshots = 0
    /// The callback of the promise now on the pasteboard, as the system would run it.
    var onRead: (@Sendable () -> Void)?

    func snapshot() -> PasteboardSnapshot {
        snapshots += 1
        return contents
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        contents = snapshot
        changeCount += 1
    }

    func write(_ string: String, markers: [String]) {
        writes.append((string, markers))
        contents = PasteboardSnapshot(items: [[text(string)] + markers.map { PasteboardRepresentation(type: $0, data: Data()) }])
        changeCount += 1
    }

    func writePromise(_ string: String, markers: [String], onRead: @escaping @Sendable () -> Void) {
        write(string, markers: markers)
        self.onRead = onRead
    }

    /// Something reads the promised text.
    func read() { onRead?() }

    func externalCopy(_ string: String) {
        contents = PasteboardSnapshot(items: [[text(string)]])
        changeCount += 1
    }
}

@MainActor
private final class FakePoster: PasteEventPosting {
    var posts = 0
    var keyCodes: [CGKeyCode] = []
    var targetPIDs: [pid_t?] = []
    var succeeds = true
    /// What the clipboard held when the paste event went out.
    var onPost: (() -> Void)?

    func postPaste(keyCode: CGKeyCode, targetPID: pid_t?) -> Bool {
        targetPIDs.append(targetPID)
        return postPaste(keyCode: keyCode)
    }

    func postPaste(keyCode: CGKeyCode) -> Bool {
        posts += 1
        keyCodes.append(keyCode)
        onPost?()
        return succeeds
    }
}

@MainActor
private final class FakeKeys: PasteKeyResolving {
    var code: CGKeyCode? = 9
    func pasteKeyCode() -> CGKeyCode? { code }
}

@MainActor
private final class FakeFocus: FocusReading {
    var current = FocusSnapshot(pid: 100, bundleID: "com.example.app", appName: "Example")
    var before: TextBeforeCursor = .unknown
    var isSecureInputEnabled = false
    var beforeReads = 0
    /// What the field reads as on each call, the last one repeating. Empty reads as unreadable.
    var readings: [FieldReading] = []
    var reads = 0

    func snapshot() -> FocusSnapshot { current }

    func readField(of element: FocusedElement) -> FieldReading {
        defer { reads += 1 }
        guard !readings.isEmpty else { return FieldReading() }
        return readings[min(reads, readings.count - 1)]
    }

    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor {
        beforeReads += 1
        return before
    }
}

private func element(_ pid: pid_t) -> FocusedElement {
    FocusedElement(AXUIElementCreateApplication(pid))
}

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class InputCounter {
    var value: UInt64? = 0
}

@MainActor
private final class BatchPauses {
    var observe: ((TimeInterval) -> Void)?
    func pause(_ delay: TimeInterval) async {
        observe?(delay)
        await Task.yield()
    }
}

@MainActor
private struct Rig {
    let input = InputCounter()
    let clock = TestClock()
    let pasteboard = FakePasteboard()
    let poster = FakePoster()
    let focus = FakeFocus()
    let keys = FakeKeys()
    let pending = Pending()
    let pauses = BatchPauses()
    let inserter: TextInserter

    final class Pending {
        /// Every delay ever scheduled, in order.
        var delays: [TimeInterval] = []
        var works: [@MainActor () -> Void] = []
        private var waiting: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        func add(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            delays.append(delay)
            works.append(work)
            waiting.append((delay, work))
        }

        @MainActor func runAll() {
            let current = waiting
            works = []
            waiting = []
            current.forEach { $0.work() }
        }

        /// Fires only the earliest timer scheduled for `delay`, then runs `after`.
        @MainActor func runFirst(_ delay: TimeInterval, after: () -> Void) {
            guard let index = waiting.firstIndex(where: { $0.delay == delay }) else { return }
            let due = waiting.remove(at: index)
            works = waiting.map(\.work)
            due.work()
            after()
        }

        /// Fires what was scheduled for `delay`, as if that much time had passed.
        @MainActor func run(_ delay: TimeInterval) {
            let due = waiting.filter { $0.delay == delay }
            waiting.removeAll { $0.delay == delay }
            works = waiting.map(\.work)
            due.forEach { $0.work() }
        }
    }

    init(restrictedToPID: pid_t? = nil, chunks: Bool = false) {
        let pauses = pauses
        let pending = pending
        let clock = clock
        let input = input
        inserter = TextInserter(focus: focus, pasteboard: pasteboard, poster: poster, keys: keys, schedule: { delay, work in
            pending.add(delay, work)
        }, sleep: { delay in if chunks { await pauses.pause(delay) } }, now: { clock.date }, inputGeneration: { input.value },
                                restrictedToPID: restrictedToPID, chunkedPaste: { _ in chunks })
    }
}

@MainActor
@Suite struct TextInserterTests {
    @Test func longPasteWaitsForEachReceiptAndRestoresOneOriginalClipboard() async {
        let rig = Rig(chunks: true)
        rig.pasteboard.contents = PasteboardSnapshot(items: [[text("original clipboard")]])
        let original = rig.pasteboard.contents
        rig.poster.onPost = { Task { @MainActor in rig.pasteboard.read() } }
        let passage = String(repeating: "Sentence 👩🏽‍💻.\n", count: 180)
        let result = await rig.inserter.deliver(passage, startFocus: nil)
        #expect(result.method == .paste && result.outcome == .unknown)
        #expect(rig.poster.posts > 1)
        #expect(rig.pasteboard.writes.map(\.text).joined() == passage)
        #expect(rig.pasteboard.snapshots == 1)
        #expect(rig.poster.targetPIDs.allSatisfy { $0 == 100 })
        rig.pending.runAll()
        #expect(rig.pasteboard.contents == original)
    }

    @Test func longPasteWithoutAReceiptStopsAfterTheFirstPart() async {
        let rig = Rig(chunks: true)
        let passage = String(repeating: "word ", count: 600)
        let result = await rig.inserter.deliver(passage, startFocus: nil)
        #expect(rig.poster.posts == 1)
        #expect(result.outcome == .partialPaste)
        #expect(result.finalText == passage)
        #expect(DeliveryCard.forDelivery(result, transcript: passage)?.header.contains("Some text") == true)
    }

    @Test(arguments: ["focus", "window", "input", "clipboard", "secure", "cancel"])
    func longPasteStopsOnInterference(change: String) async {
        let rig = Rig(chunks: true)
        let passage = String(repeating: "word ", count: 600)
        rig.poster.onPost = {
            Task { @MainActor in
                rig.pasteboard.read()
                switch change {
                case "focus": rig.focus.current.pid = 101
                case "window": rig.focus.current.windowTitle = "Another tab"
                case "input": rig.input.value = 1
                case "clipboard": rig.pasteboard.externalCopy("new user copy")
                case "secure": rig.focus.isSecureInputEnabled = true
                default: rig.inserter.cancelVerification()
                }
            }
        }
        let result = await rig.inserter.deliver(passage, startFocus: nil)
        #expect(rig.poster.posts == 1)
        #expect(result.outcome == .partialPaste)
        rig.pending.runAll()
        if change == "clipboard" {
            #expect(rig.pasteboard.contents == PasteboardSnapshot(items: [[text("new user copy")]]))
        }
    }

    @Test func chunkingNeverTreatsAnEarlyClipboardManagerReadAsPermissionToAdvance() async {
        let rig = Rig(chunks: true)
        rig.poster.onPost = { rig.pasteboard.read() }
        let result = await rig.inserter.deliver(String(repeating: "word ", count: 600), startFocus: nil)
        #expect(result.outcome == .partialPaste && rig.poster.posts == 1)
    }

    @Test func aConcurrentDeliveryCannotInterleaveWithAPartialPaste() async throws {
        let rig = Rig(chunks: true)
        var other: Task<DeliveryResult, Never>?
        rig.poster.onPost = {
            if other == nil { other = Task { await rig.inserter.deliver("new dictation", startFocus: nil) } }
            Task { @MainActor in rig.pasteboard.read() }
        }
        let passage = String(repeating: "word ", count: 600)
        let result = await rig.inserter.deliver(passage, startFocus: nil)
        let concurrent = try #require(other)
        #expect(await concurrent.value.method == .none)
        #expect(result.outcome == .unknown && rig.pasteboard.writes.map(\.text).joined() == passage)
    }

    @Test func aFailedChunkDoesNotAutomaticallyRetryOrReplaceTheClipboardWithTheWholePassage() async {
        let rig = Rig(chunks: true)
        rig.poster.succeeds = false
        let passage = String(repeating: "word ", count: 600)
        let result = await rig.inserter.deliver(passage, startFocus: nil)
        #expect(result.outcome == .partialPaste && result.storeOutcome == "unknown")
        #expect(rig.poster.posts == 1 && rig.pasteboard.writes.count == 1)
        #expect(rig.pasteboard.writes.first?.text != passage)
        rig.pending.runAll()
        #expect(!rig.inserter.isRestorePending)
    }

    @Test func aLateReceiptGetsItsOwnSettleDelayBeforeTheNextPart() async {
        let rig = Rig(chunks: true)
        var settles = 0
        var postsAtSecondSettle: Int?
        defer { rig.pauses.observe = nil }
        rig.pauses.observe = { delay in
            guard delay == PasteboardSession.receiptSettle else { return }
            settles += 1
            if settles == 1 { rig.pasteboard.read() }
            if settles == 2 { postsAtSecondSettle = rig.poster.posts }
        }
        rig.poster.onPost = { Task { @MainActor in rig.pasteboard.read() } }
        let result = await rig.inserter.deliver(String(repeating: "word ", count: 600), startFocus: nil)
        #expect(result.outcome == .unknown)
        #expect(postsAtSecondSettle == 1)
    }

    @Test func aNewPasteBorrowsTheUsersLatestCopyInsteadOfAnOlderPendingSnapshot() async {
        let rig = Rig(chunks: true)
        _ = await rig.inserter.deliver("first take", startFocus: nil)
        rig.pasteboard.externalCopy("new user copy")
        let copied = rig.pasteboard.contents
        rig.poster.onPost = { Task { @MainActor in rig.pasteboard.read() } }
        _ = await rig.inserter.deliver(String(repeating: "word ", count: 600), startFocus: nil)
        rig.pending.runAll()
        #expect(rig.pasteboard.contents == copied)
    }

    @Test func systemPosterSendsOneStampedCommandVPairToTheDestination() {
        var pids: [pid_t] = []
        var types: [CGEventType] = []
        var flags: [CGEventFlags] = []
        var stamps: [Int64] = []
        let poster = SystemPasteEventPoster(stamp: 1234, post: { event, pid in
            pids.append(pid); types.append(event.type); flags.append(event.flags)
            stamps.append(event.getIntegerValueField(.eventSourceUserData))
        })
        #expect(poster.postPaste(keyCode: 9, targetPID: 321))
        #expect(pids == [321, 321])
        #expect(types == [.keyDown, .keyUp])
        #expect(flags == [.maskCommand, .maskCommand])
        #expect(stamps == [1234, 1234])
    }

    @Test func missingOrInvalidDestinationsNeverPostToAnAmbientApp() {
        var posts = 0
        let poster = SystemPasteEventPoster(stamp: 1, post: { _, _ in posts += 1 })
        #expect(!poster.postPaste(keyCode: 9, targetPID: nil))
        #expect(!poster.postPaste(keyCode: 9, targetPID: 0))
        #expect(!poster.postPaste(keyCode: 9, targetPID: -1))
        #expect(posts == 0)
    }

    @Test func diagnosticsRemainRestrictedToTheirOwnProcess() {
        var pids: [pid_t] = []
        let poster = SystemPasteEventPoster(stamp: 1, targetPID: 123, post: { _, pid in pids.append(pid) })
        #expect(poster.postPaste(keyCode: 9, targetPID: 321))
        #expect(pids == [123, 123])
    }

    @Test func pasteTargetsTheCapturedDestinationProcess() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 321, bundleID: "com.example.target", appName: "Target")
        _ = await rig.inserter.deliver("one insertion", startFocus: nil)
        #expect(rig.poster.targetPIDs == [321])
        #expect(rig.poster.posts == 1)
    }

    @Test(arguments: [Optional<pid_t>.none, 200])
    func aSelfTestCannotPasteOrCopyIntoAnotherProcess(pid: pid_t?) async {
        let rig = Rig(restrictedToPID: 100)
        rig.focus.current.pid = pid
        let result = await rig.inserter.deliver("Only for the test window", startFocus: nil)
        #expect(result.method == .none)
        #expect(rig.poster.posts == 0 && rig.pasteboard.writes.isEmpty)
    }

    @Test func aSelfTestCanStillPasteIntoItsOwnProcess() async {
        let rig = Rig(restrictedToPID: 100)
        let result = await rig.inserter.deliver("Only for the test window", startFocus: nil)
        #expect(result.method == .paste && rig.poster.posts == 1)
    }

    @Test func restoredHistoryCanBeCopiedAndPastedWithoutAClipboardWriteAtLaunch() async throws {
        let rig = Rig()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-last-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let id = try store.begin(DictationStart())
        try store.recordInsertion(id, InsertionRecord(finalText: "Saved before restart"))
        try rig.inserter.restoreLast(from: store)
        #expect(rig.pasteboard.writes.isEmpty && rig.poster.posts == 0)
        #expect(rig.inserter.copyLast())
        #expect(rig.pasteboard.writes.last?.text == "Saved before restart")
        let delivered = await rig.inserter.pasteLast()
        #expect(delivered?.finalText == "Saved before restart" && rig.poster.posts == 1)
    }

    private let original = PasteboardSnapshot(items: [
        [
            PasteboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            PasteboardRepresentation(type: "public.tiff", data: Data([0x49, 0x49])),
        ],
        [text("second item")],
    ])

    @Test func pasteWritesTheTranscriptWithAllThreeMarkerTypes() async {
        let rig = Rig()
        let result = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(result.method == .paste)
        #expect(result.finalText == "hello")
        #expect(rig.poster.posts == 1)
        let write = try? #require(rig.pasteboard.writes.first)
        #expect(write?.text == "hello")
        #expect(Set(write?.markers ?? []) == [
            "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
        ])
    }

    @Test func restoresEveryItemAndTypeAfterTheDelay() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(rig.pending.delays == [PasteboardSession.receiptCap])
        #expect(rig.pasteboard.contents != original)
        rig.pending.runAll()
        #expect(rig.pasteboard.contents == original)
        #expect(rig.pasteboard.contents.items.count == 2)
        #expect(rig.pasteboard.contents.items[0].count == 2)
    }

    @Test func skipsTheRestoreWhenTheClipboardChangedMeanwhile() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.pasteboard.externalCopy("user copied this")
        rig.pending.runAll()
        #expect(rig.pasteboard.contents.items == [[text("user copied this")]])
    }

    @Test func aSecondPasteBeforeTheRestoreKeepsTheUsersClipboard() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("one", startFocus: nil)
        _ = await rig.inserter.deliver("two", startFocus: nil)
        rig.pending.runAll()
        #expect(rig.pasteboard.contents == original)
    }

    @Test func pastesAfterWritingNotBefore() async {
        let rig = Rig()
        var seen: PasteboardSnapshot?
        rig.poster.onPost = { seen = rig.pasteboard.contents }
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(seen?.items.first?.contains(text("hello")) == true)
    }

    @Test func secureFieldDiscardsAndNeverTouchesThePasteboard() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        rig.focus.current.isSecure = true
        let result = await rig.inserter.deliver("hunter2", startFocus: nil)
        #expect(result.method == .none)
        #expect(result.outcome == .secureDiscard)
        #expect(result.finalText.isEmpty)
        #expect(rig.pasteboard.writes.isEmpty)
        #expect(rig.pasteboard.snapshots == 0)
        #expect(rig.pasteboard.contents == original)
        #expect(rig.poster.posts == 0)
        #expect(rig.pending.works.isEmpty)
        #expect(await rig.inserter.pasteLast() == nil)
    }

    @Test func secureInputWithNoReadableFieldDiscards() async {
        let rig = Rig()
        rig.focus.isSecureInputEnabled = true
        let result = await rig.inserter.deliver("x", startFocus: nil)
        #expect(result.outcome == .secureDiscard)
        #expect(result.target?.isSecure == true)
        #expect(rig.pasteboard.writes.isEmpty)
        #expect(rig.poster.posts == 0)
    }

    @Test func secureInputWithAReadableNormalFieldPastes() async {
        let rig = Rig()
        rig.focus.isSecureInputEnabled = true
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        let result = await rig.inserter.deliver("x", startFocus: nil)
        #expect(result.method == .paste)
        #expect(result.outcome == .unknown)
        #expect(rig.poster.posts == 1)
    }

    @Test func aSecureFieldAtStartButANormalOneAtDeliveryPastes() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        let start = FocusSnapshot(pid: 100, isSecure: true, element: element(100))
        let result = await rig.inserter.deliver("x", startFocus: start)
        #expect(result.method == .paste)
        #expect(rig.poster.posts == 1)
    }

    @Test func aNormalFieldAtStartButASecureOneAtDeliveryDiscards() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, isSecure: true, element: element(100))
        let start = FocusSnapshot(pid: 100, element: element(100))
        let result = await rig.inserter.deliver("x", startFocus: start)
        #expect(result.outcome == .secureDiscard)
        #expect(rig.poster.posts == 0)
    }

    @Test func focusMovedIsRecordedAndPasteStillGoesToTheNewFocus() async {
        let rig = Rig()
        let start = FocusSnapshot(pid: 1, element: element(1))
        rig.focus.current = FocusSnapshot(pid: 2, bundleID: "com.example.other", element: element(2))
        let result = await rig.inserter.deliver("hello", startFocus: start)
        #expect(result.focusMoved)
        #expect(result.method == .paste)
        #expect(result.target?.bundleID == "com.example.other")
    }

    @Test func unchangedFocusIsNotMoved() async {
        let rig = Rig()
        let start = FocusSnapshot(pid: 5, element: element(5))
        rig.focus.current = FocusSnapshot(pid: 5, element: element(5))
        #expect(await rig.inserter.deliver("hi", startFocus: start).focusMoved == false)
    }

    @Test func anElementSeenOnlyOnceIsNotMovement() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 5, element: element(5))
        #expect(await rig.inserter.deliver("hi", startFocus: FocusSnapshot(pid: 5)).focusMoved == false)
        #expect(await rig.inserter.deliver("hi", startFocus: nil).focusMoved == false)
    }

    @Test func aDifferentAppIsMovement() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 6)
        #expect(await rig.inserter.deliver("hi", startFocus: FocusSnapshot(pid: 5)).focusMoved)
    }

    @Test func leadingSpaceComesFromTheTextBeforeTheCursor() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.before = .character("o")
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == " world")
        rig.focus.before = .character(" ")
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
    }

    @Test func spacingIsSkippedWhenThereIsNoElement() async {
        let rig = Rig()
        rig.focus.before = .character("o")
        let result = await rig.inserter.deliver("world", startFocus: nil)
        #expect(rig.focus.beforeReads == 0)
        #expect(result.finalText == "world")
    }

    // MARK: - Continuing after our own last paste when the text before the cursor can't be read

    @Test func twoDeliveriesToTheSameAppWithNoReadableContextGetASpaceBetween() async {
        let rig = Rig()
        #expect(await rig.inserter.deliver("My name is Hove.", startFocus: nil).finalText == "My name is Hove.")
        rig.clock.advance(30)
        #expect(await rig.inserter.deliver("Damn, can you check", startFocus: nil).finalText == " Damn, can you check")
    }

    @Test(arguments: [false, true])
    func staleOrcaContextCannotJoinConsecutiveSentences(reportsSpace: Bool) async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.stablyai.orca", role: "AXTextField", element: element(100))
        rig.focus.before = reportsSpace ? .character(" ") : .start
        _ = await rig.inserter.deliver("This sentence is running together.", startFocus: nil)
        rig.clock.advance(15)
        #expect(await rig.inserter.deliver("It doesn't seem like spacing works.", startFocus: nil).finalText == " It doesn't seem like spacing works.")
    }

    @Test func submittingOrMovingWithinOrcaDoesNotReuseTheOldSentenceEnding() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.stablyai.orca", role: "AXTextField", element: element(100))
        rig.focus.before = .start
        _ = await rig.inserter.deliver("Previous message.", startFocus: nil)
        rig.input.value = 1
        #expect(await rig.inserter.deliver("New message.", startFocus: nil).finalText == "New message.")
    }

    @Test func aKeyPressBetweenDeliveriesGetsNoSpace() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("My name is Hove.", startFocus: nil)
        rig.input.value = 1
        #expect(await rig.inserter.deliver("Damn, can you check", startFocus: nil).finalText == "Damn, can you check")
    }

    @Test func aClickBetweenDeliveriesGetsNoSpaceAndOnlyTheNextOneRearms() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("one", startFocus: nil)
        rig.input.value = 5
        #expect(await rig.inserter.deliver("two", startFocus: nil).finalText == "two")
        #expect(await rig.inserter.deliver("three", startFocus: nil).finalText == " three")
    }

    @Test func theInputCountIsTakenAfterThePasteEventGoesOut() async {
        let rig = Rig()
        let input = rig.input
        rig.poster.onPost = { input.value = (input.value ?? 0) + 2 }
        _ = await rig.inserter.deliver("one", startFocus: nil)
        #expect(await rig.inserter.deliver("two", startFocus: nil).finalText == " two")
    }

    @Test func unknownInputGetsNoSpace() async {
        let rig = Rig()
        rig.input.value = nil
        _ = await rig.inserter.deliver("one", startFocus: nil)
        #expect(await rig.inserter.deliver("two", startFocus: nil).finalText == "two")
        rig.input.value = 0
        _ = await rig.inserter.deliver("three", startFocus: nil)
        rig.input.value = nil
        #expect(await rig.inserter.deliver("four", startFocus: nil).finalText == "four")
    }

    @Test func aReadableContextIgnoresTheInputCount() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(100))
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.input.value = 9
        rig.focus.before = .character("o")
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == " world")
    }

    @Test func aListAfterAnUnreadablePasteStartsOnANewLineAndKeepsTheContinuation() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("Groceries:", startFocus: nil)
        rig.clock.advance(30)
        #expect(await rig.inserter.deliver("- Milk\n- Eggs", startFocus: nil).finalText == "\n- Milk\n- Eggs")
        rig.clock.advance(30)
        #expect(await rig.inserter.deliver("Thanks", startFocus: nil).finalText == " Thanks")
    }

    @Test func aResultStartingWithANewlineGetsNoLeadingSpace() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("Hello", startFocus: nil)
        #expect(await rig.inserter.deliver("\nWorld", startFocus: nil).finalText == "\nWorld")
    }

    @Test func theFirstEverDeliveryGetsNoSpace() async {
        let rig = Rig()
        #expect(await rig.inserter.deliver("hello", startFocus: nil).finalText == "hello")
    }

    @Test func aDifferentAppGetsNoSpace() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.focus.current = FocusSnapshot(pid: 200, bundleID: "com.example.other")
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
    }

    @Test func aDifferentFocusedElementInTheSameAppGetsNoSpace() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(100))
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(101))
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
    }

    @Test func outsideTheWindowGetsNoSpace() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.clock.advance(TextInserter.continuationWindow + 1)
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
    }

    @Test func atTheEdgeOfTheWindowStillGetsASpace() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.clock.advance(TextInserter.continuationWindow)
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == " world")
    }

    @Test func aPreviousPasteEndingInNewlineSpaceOrOpenerGetsNoSpace() async {
        for ending in ["hello\n", "hello ", "hello ("] {
            let rig = Rig()
            _ = await rig.inserter.deliver(ending, startFocus: nil)
            #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
        }
    }

    @Test func readableContextOverridesTheFallbackBothWays() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(100))
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.focus.before = .character(" ")
        #expect(await rig.inserter.deliver("world", startFocus: nil).finalText == "world")
        rig.focus.before = .start
        #expect(await rig.inserter.deliver("again", startFocus: nil).finalText == "again")

        let other = Rig()
        other.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(100))
        other.focus.before = .character("x")
        _ = await other.inserter.deliver("hello.", startFocus: nil)
        #expect(await other.inserter.deliver("world", startFocus: nil).finalText == " world")
        // Last paste ended in a space-free opener, but the field says a word precedes the cursor.
        let third = Rig()
        third.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", element: element(100))
        _ = await third.inserter.deliver("hello (", startFocus: nil)
        third.focus.before = .character("o")
        #expect(await third.inserter.deliver("world", startFocus: nil).finalText == " world")
    }

    @Test func aClipboardOnlyDeliveryIsNotTheLastPaste() async {
        let rig = Rig()
        _ = await rig.inserter.deliver("first.", startFocus: nil)
        rig.poster.succeeds = false
        #expect(await rig.inserter.deliver("lost", startFocus: nil).method == .clipboardOnly)
        rig.poster.succeeds = true
        // Memory still holds "first." so a space is added, not driven by "lost".
        #expect(await rig.inserter.deliver("next", startFocus: nil).finalText == " next")

        let fresh = Rig()
        fresh.poster.succeeds = false
        _ = await fresh.inserter.deliver("lost", startFocus: nil)
        fresh.poster.succeeds = true
        #expect(await fresh.inserter.deliver("next", startFocus: nil).finalText == "next")

        let nothing = Rig()
        nothing.focus.current = FocusSnapshot()
        _ = await nothing.inserter.deliver("lost", startFocus: nil)
        nothing.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app")
        #expect(await nothing.inserter.deliver("next", startFocus: nil).finalText == "next")
    }

    @Test func nothingFrontmostLeavesTheTextOnTheClipboardWithoutRestoring() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        rig.focus.current = FocusSnapshot()
        let result = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(result.method == .clipboardOnly)
        #expect(result.finalText == "hello")
        #expect(rig.poster.posts == 0)
        #expect(rig.pending.works.isEmpty)
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
    }

    @Test func aFailedPostLeavesTheTextOnTheClipboard() async {
        let rig = Rig()
        rig.poster.succeeds = false
        let result = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(result.method == .clipboardOnly)
        #expect(result.outcome == .failed("paste event could not be posted"))
        #expect(rig.pending.works.isEmpty)
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
    }

    @Test func emptyTextDoesNothing() async {
        let rig = Rig()
        let result = await rig.inserter.deliver("", startFocus: nil)
        #expect(result.method == .none)
        #expect(rig.pasteboard.writes.isEmpty)
    }

    @Test func pasteLastRepastesTheLastTranscriptAndCopyLastKeepsIt() async {
        let rig = Rig()
        #expect(await rig.inserter.pasteLast() == nil)
        #expect(rig.inserter.copyLast() == false)

        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.pending.runAll()
        let again = await rig.inserter.pasteLast()
        #expect(again?.method == .paste)
        #expect(again?.finalText == " hello")
        #expect(rig.poster.posts == 2)

        #expect(rig.inserter.copyLast())
        rig.pending.runAll()
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
        #expect(rig.pasteboard.writes.last?.markers.contains("org.nspasteboard.ConcealedType") == true)
    }

    // MARK: - The paste key

    @Test func theResolvedKeyIsTheOneThatIsPosted() async {
        let rig = Rig()
        rig.keys.code = 47
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(rig.poster.keyCodes == [47])
    }

    @Test func noPasteKeyFailsLoudlyAndLeavesTheTextOnTheClipboard() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        rig.keys.code = nil
        let result = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(result.method == .clipboardOnly)
        #expect(result.outcome == .failed("no paste key in this keyboard layout"))
        #expect(result.finalText == "hello")
        #expect(rig.poster.posts == 0)
        #expect(rig.pending.works.isEmpty)
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
        #expect(DeliveryCard.forDelivery(result, transcript: "hello")?.kind == .pasteFailed)
    }

    // MARK: - Read receipts

    /// Lets the hop from the pasteboard's callback to the main actor run.
    private func hop() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aReceiptRestoresTheClipboard200msLater() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(rig.pending.delays == [PasteboardSession.receiptCap])
        rig.pasteboard.read()
        await hop()
        #expect(rig.pending.delays == [PasteboardSession.receiptCap, 0.2])
        #expect(rig.pasteboard.contents != original)
        rig.pending.run(0.2)
        #expect(rig.pasteboard.contents == original)
    }

    @Test func theRestoreWaitsForTheLastReceipt() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.pasteboard.read()
        await hop()
        rig.pasteboard.read()
        await hop()
        #expect(rig.pending.delays == [PasteboardSession.receiptCap, 0.2, 0.2])
        // The first receipt's timer fires, but a later receipt moved the deadline.
        rig.pending.runFirst(0.2) {}
        #expect(rig.pasteboard.contents != original)
        rig.pending.run(0.2)
        #expect(rig.pasteboard.contents == original)
    }

    @Test func noReceiptRestoresAtTheCap() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(PasteboardSession.receiptCap == 8)
        rig.pending.run(PasteboardSession.receiptCap)
        #expect(rig.pasteboard.contents == original)
    }

    @Test func aMovedChangeCountMeansNoRestoreAfterAReceipt() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        rig.pasteboard.read()
        await hop()
        rig.pasteboard.externalCopy("user copied this")
        rig.pending.run(0.2)
        #expect(rig.pasteboard.contents.items == [[text("user copied this")]])
    }

    @Test func aReadBeforeTheChordIsNotAReceiptAndRestoresOnAFixedDelay() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        let board = rig.pasteboard
        rig.poster.onPost = { board.read() }
        var verified: [PasteVerification] = []
        rig.inserter.observeVerification { verified.append($0) }
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        await hop()
        await rig.inserter.waitForVerification()
        #expect(rig.pending.delays == [PasteboardSession.unobservedDelay])
        rig.pending.run(PasteboardSession.unobservedDelay)
        #expect(rig.pasteboard.contents == original)
        #expect(verified.count == 1 && verified.first?.receiptMs == nil)
    }

    @Test func aStaleReceiptFromAnEarlierPasteIsIgnored() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("one", startFocus: nil)
        let stale = rig.pasteboard.onRead
        _ = await rig.inserter.deliver("two", startFocus: nil)
        stale?()
        await hop()
        #expect(!rig.pending.delays.contains(0.2))
        rig.pasteboard.read()
        await hop()
        #expect(rig.pending.delays.filter { $0 == 0.2 }.count == 1)
        rig.pending.run(0.2)
        #expect(rig.pasteboard.contents == original)
    }

    @Test func aReceiptAfterACopyDoesNotRestore() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        _ = await rig.inserter.deliver("hello", startFocus: nil)
        let promise = rig.pasteboard.onRead
        #expect(rig.inserter.copyLast())
        promise?()
        await hop()
        rig.pending.runAll()
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
    }

    // MARK: - Refusing a target that can't take text

    @Test func aButtonIsRefusedAndTheTextStaysOnTheClipboard() async {
        let rig = Rig()
        rig.pasteboard.contents = original
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", role: "AXButton", element: element(100))
        let result = await rig.inserter.deliver("hello", startFocus: nil)
        #expect(result.method == .clipboardOnly && result.outcome == .unknown)
        #expect(result.finalText == "hello")
        #expect(rig.poster.posts == 0 && rig.pending.works.isEmpty)
        #expect(rig.pasteboard.contents.items.first?.contains(text("hello")) == true)
        #expect(DeliveryCard.forDelivery(result, transcript: "hello")?.kind == .nowhere)
        #expect(result.verificationID == nil)
    }

    @Test func containersAndUnknownRolesPasteAnyway() async {
        for role in ["AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", "AXNothingWeKnow", nil] {
            let rig = Rig()
            rig.focus.current = FocusSnapshot(pid: 100, role: role, element: element(100))
            #expect(await rig.inserter.deliver("hello", startFocus: nil).method == .paste, "\(role ?? "nil")")
        }
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100)
        #expect(await rig.inserter.deliver("hello", startFocus: nil).method == .paste)
    }

    @Test func staticTextIsRefusedOnlyWhenItsTextCannotBeSet() async {
        let fixed = Rig()
        fixed.focus.current = FocusSnapshot(pid: 100, role: "AXStaticText", isTextSettable: false, element: element(100))
        #expect(await fixed.inserter.deliver("hello", startFocus: nil).method == .clipboardOnly)
        let field = Rig()
        field.focus.current = FocusSnapshot(pid: 100, role: "AXStaticText", isTextSettable: true, element: element(100))
        #expect(await field.inserter.deliver("hello", startFocus: nil).method == .paste)
    }

    // MARK: - The read-back

    private static let before = FieldReading(value: "Hello", length: 5, selection: NSRange(location: 5, length: 0))

    private func verified(_ rig: Rig, readings: [FieldReading], text: String = "world") async -> [PasteVerification] {
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.example.app", role: "AXTextArea", element: element(100))
        rig.focus.readings = readings
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver(text, startFocus: nil)
        await rig.inserter.waitForVerification()
        return seen
    }

    @Test func deliverDoesNotWaitForTheReadBack() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        let result = await rig.inserter.deliver("world", startFocus: nil)
        #expect(result.method == .paste && result.verificationID != nil)
        #expect(seen.isEmpty)
        await rig.inserter.waitForVerification()
        #expect(seen.count == 1)
    }

    @Test func aFieldThatNeverChangedIsNotLanded() async {
        let rig = Rig()
        let seen = await verified(rig, readings: [Self.before])
        #expect(seen.map(\.verdict) == [.notLanded])
        #expect(seen.first?.id == 1)
        #expect(rig.focus.reads == 4)
        #expect(rig.poster.posts == 1)
    }

    @Test func aTerminalScreenDoesNotProveThatInputWasLost() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.apple.Terminal", role: "AXTextArea", element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        let result = await rig.inserter.deliver("world", startFocus: nil)
        await rig.inserter.waitForVerification()
        #expect(result.method == .paste && rig.poster.posts == 1)
        #expect(seen.map(\.verdict) == [.unknown])
    }

    @Test func anUnchangedOrcaFieldDoesNotProveThatInputWasLost() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.stablyai.orca", role: "AXTextField", element: element(100))
        rig.focus.readings = [Self.before]
        rig.poster.onPost = { rig.pasteboard.read() }
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        let result = await rig.inserter.deliver("world", startFocus: nil)
        await rig.inserter.waitForVerification()
        #expect(result.method == .paste && rig.poster.posts == 1)
        #expect(seen.map(\.verdict) == [.unknown])
        #expect(seen.allSatisfy { DeliveryCard.forVerdict($0.verdict, transcript: "world") == nil })
    }

    @Test func anOrcaFieldThatActuallyUpdatesCanStillConfirmDelivery() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, bundleID: "com.stablyai.orca", role: "AXTextField", element: element(100))
        rig.focus.readings = [Self.before, FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.verdict) == [.confirmed])
    }

    @Test func aFieldThatGrewIsConfirmedAtTheFirstReadAndStopsReading() async {
        let rig = Rig()
        let grown = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        let seen = await verified(rig, readings: [Self.before, grown])
        #expect(seen.map(\.verdict) == [.confirmed])
        #expect(rig.focus.reads == 2)
    }

    @Test func aLateLandingIsStillConfirmed() async {
        let rig = Rig()
        let grown = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        let seen = await verified(rig, readings: [Self.before, Self.before, Self.before, grown])
        #expect(seen.map(\.verdict) == [.confirmed])
    }

    @Test func inputInBetweenIsUnknown() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        rig.input.value = 3
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.verdict) == [.unknown])
    }

    @Test func anUnknownInputCountIsUnknown() async {
        let rig = Rig()
        rig.input.value = nil
        let seen = await verified(rig, readings: [Self.before])
        #expect(seen.map(\.verdict) == [.unknown])
    }

    @Test func focusMovingIsUnknown() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        rig.focus.current = FocusSnapshot(pid: 100, element: element(101))
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.verdict) == [.unknown])
        #expect(rig.focus.reads == 1)
    }

    @Test func aFieldThatTurnsSecureIsNotRead() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        rig.focus.current = FocusSnapshot(pid: 100, isSecure: true, element: element(100))
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.verdict) == [.unknown])
        #expect(rig.focus.reads == 1)
    }

    @Test func anUnreadableFieldIsUnknown() async {
        let rig = Rig()
        let seen = await verified(rig, readings: [])
        #expect(seen.map(\.verdict) == [.unknown])
    }

    @Test func noFocusedElementMeansNothingToRead() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100)
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.verdict) == [.unknown])
        #expect(rig.focus.reads == 0)
    }

    @Test func theReceiptTimeRidesAlongWithTheVerdict() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("world", startFocus: nil)
        rig.pasteboard.read()
        await hop()
        await rig.inserter.waitForVerification()
        #expect((seen.first?.receiptMs ?? -1) >= 0)
    }

    @Test func aNewerDeliveryRetiresTheOlderReadBack() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        let first = await rig.inserter.deliver("one", startFocus: nil)
        let second = await rig.inserter.deliver("two", startFocus: nil)
        await rig.inserter.waitForVerification()
        #expect(seen.map(\.id) == [second.verificationID])
        #expect(first.verificationID != second.verificationID)
    }

    @Test func cancellingTheReadBackSaysNothingAndNeverRepastes() async {
        let rig = Rig()
        rig.focus.current = FocusSnapshot(pid: 100, element: element(100))
        rig.focus.readings = [Self.before]
        var seen: [PasteVerification] = []
        rig.inserter.observeVerification { seen.append($0) }
        _ = await rig.inserter.deliver("one", startFocus: nil)
        rig.inserter.cancelVerification()
        await rig.inserter.waitForVerification()
        #expect(seen.isEmpty)
        #expect(rig.poster.posts == 1)
    }

    @Test func resultsMapOntoTheStoreVocabulary() {
        func result(_ method: DeliveryResult.Method, _ outcome: DeliveryResult.Outcome) -> DeliveryResult {
            DeliveryResult(method: method, outcome: outcome, focusMoved: false, target: nil, finalText: "")
        }
        #expect(result(.paste, .unknown).storeMethod == "paste")
        #expect(result(.clipboardOnly, .unknown).storeMethod == "clipboard only")
        #expect(result(.none, .secureDiscard).storeMethod == "none")
        #expect(result(.none, .secureDiscard).storeOutcome == "secure discard")
        #expect(result(.clipboardOnly, .failed("x")).storeOutcome == "not landed")
        #expect(result(.paste, .unknown).storeOutcome == "unknown")
        #expect(DeliveryCard.forDelivery(result(.paste, .unknown), transcript: "x") == nil)
    }

    @Test func snapshotConvertsToTheStoreTarget() {
        let snapshot = FocusSnapshot(
            pid: 3, bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Shopping", role: "AXTextArea", isSecure: false
        )
        let target = snapshot.target
        #expect(target.bundleID == "com.apple.Notes")
        #expect(target.appName == "Notes")
        #expect(target.windowTitle == "Shopping")
        #expect(target.fieldRole == "AXTextArea")
        #expect(target.isSecure == false)
    }
}
