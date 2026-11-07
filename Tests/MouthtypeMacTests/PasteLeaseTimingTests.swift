import AppKit
import Testing
@testable import MouthtypeMac

private func plain(_ s: String) -> PasteboardRepresentation {
    PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(s.utf8))
}

@MainActor
private final class LeasePasteboard: PasteboardAccess {
    var changeCount = 0
    var contents = PasteboardSnapshot(items: [[plain("user clipboard")]])
    var snapshots = 0
    var lastMarkers: [String] = []
    var lastWasPromise = false
    var onRead: (@Sendable () -> Void)?

    var text: String? {
        guard let value = contents.items.first?.first(where: { $0.type == "public.utf8-plain-text" }) else { return nil }
        return String(data: value.data, encoding: .utf8)
    }

    func snapshot() -> PasteboardSnapshot {
        snapshots += 1
        return contents
    }
    func restore(_ snapshot: PasteboardSnapshot) {
        contents = snapshot
        changeCount += 1
    }
    func write(_ string: String, markers: [String]) {
        contents = PasteboardSnapshot(items: [[plain(string)]])
        changeCount += 1
        lastMarkers = markers
        lastWasPromise = false
    }
    func writePromise(_ string: String, markers: [String], onRead: @escaping @Sendable () -> Void) {
        write(string, markers: markers)
        lastWasPromise = true
        self.onRead = onRead
    }
    func read() { onRead?() }
    func externalCopy(_ string: String) {
        contents = PasteboardSnapshot(items: [[plain(string)]])
        changeCount += 1
    }
}

@MainActor
private final class Poster: PasteEventPosting {
    var onPost: (() -> Void)?
    func postPaste(keyCode: CGKeyCode, targetPID: pid_t?) -> Bool {
        onPost?()
        return true
    }
}

/// A schedule the test moves by hand, in milliseconds. The session keeps its production constants.
@MainActor
private final class ManualTime {
    var now = 0
    private var tasks: [(at: Int, work: @MainActor () -> Void)] = []

    lazy var schedule: PasteboardSession.Schedule = { [unowned self] delay, work in
        tasks.append((now + Int((delay * 1000).rounded()), work))
    }

    func advance(to ms: Int) async {
        while let at = tasks.filter({ $0.at <= ms }).map(\.at).min() {
            let due = tasks.filter { $0.at == at }
            tasks.removeAll { $0.at == at }
            now = at
            for task in due { task.work() }
            await settle()
        }
        now = ms
    }

    /// Lets a read's hop to the main actor land.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private struct Rig {
    let board = LeasePasteboard()
    let time = ManualTime()
    let poster = Poster()
    let session: PasteboardSession

    init() {
        session = PasteboardSession(pasteboard: board, poster: poster, schedule: time.schedule)
    }

    /// Something reads the promise at `ms` after the chord.
    func read(at ms: Int) async {
        await time.advance(to: ms)
        board.read()
        await time.settle()
    }
}

@MainActor private let holdCapMs = Int(PasteboardSession.fieldHoldCap * 1000)
@MainActor private let receiptCapMs = Int(PasteboardSession.receiptCap * 1000)

@MainActor @Suite struct PasteLeaseTimingTests {
    @Test func everyTaskDueAtTheSameMillisecondRuns() async {
        let time = ManualTime()
        var ran: [Int] = []
        time.schedule(0.1) { ran.append(1) }
        time.schedule(0.1) { ran.append(2) }
        await time.advance(to: 100)
        #expect(ran == [1, 2])
    }

    @Test func aReadAfterTheDeferredRestoreMakesALaterConfirmWaitForTheSettle() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.read(at: 50)
        // The sync's settle came due at 250 with the field still unconfirmed: the restore is deferred.
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "transcript")
        // The target is still reading, so the deferred restore no longer stands.
        await rig.read(at: 300)
        await rig.time.advance(to: 350)
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 450)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 550)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func anEarlySyncReadDoesNotLetASlowTargetPasteTheOldClipboard() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.read(at: 50)
        // The sync's receipt came due at 250 ms; the field hasn't shown the text, so the clipboard stays borrowed.
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "transcript")
        await rig.read(at: 300)
        await rig.time.advance(to: 350)
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        // The second read means the target is still taking the text, so the restore waits for that read's settle.
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 500)
        #expect(rig.board.text == "user clipboard")
        #expect(!rig.session.isRestorePending)
        await rig.time.advance(to: receiptCapMs)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func aFastSingleReadRestoresOnItsSettleWhenTheFieldShowsThePasteFirst() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.read(at: 30)
        await rig.time.advance(to: 150)
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        await rig.time.advance(to: 229)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 230)
        #expect(rig.board.text == "user clipboard")
        #expect(rig.session.readCount == 1)
    }

    @Test func aHeldPasteWhoseFieldNeverShowsTheTextRestoresAtTheHoldCapNotTheReceiptCap() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.read(at: 100)
        await rig.time.advance(to: holdCapMs - 1)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: holdCapMs)
        #expect(rig.board.text == "user clipboard")
        #expect(PasteboardSession.fieldHoldCap > (TextInserter.verifyOffsets.max() ?? 0))
        #expect(PasteboardSession.fieldHoldCap <= 1.5)
    }

    @Test func aHeldPasteNobodyReadsStillWaitsForTheReceiptCap() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.time.advance(to: receiptCapMs - 1)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: receiptCapMs)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func aReadBeforeTheChordIsHeldForTheFieldToo() async {
        let rig = Rig()
        rig.poster.onPost = { [board = rig.board] in board.read() }
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        #expect(rig.session.hadEarlyRead && rig.session.readCount == 0)
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "transcript")
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func anUnheldPasteStillFallsBackToTheFixedDelayAfterAReadBeforeTheChord() async {
        let rig = Rig()
        rig.poster.onPost = { [board = rig.board] in board.read() }
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1))
        await rig.time.advance(to: 249)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 250)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func anUnheldPasteRestoresOffTheReceiptAlone() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1))
        await rig.read(at: 30)
        await rig.time.advance(to: 229)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: 230)
        #expect(rig.board.text == "user clipboard")
        #expect(rig.session.readCount == 1)
    }

    /// A native app reads the promise within a millisecond of the chord. That read is the receipt; nothing discounts it.
    @Test func aReadRightBehindTheChordIsTheTargetsReceipt() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1))
        await rig.read(at: 1)
        #expect(rig.session.readCount == 1)
        #expect(rig.session.firstReceiptMs != nil)
        await rig.time.advance(to: 201)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func fieldShowedPasteWithoutAHoldChangesNothing() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1))
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        await rig.time.advance(to: 1_000)
        #expect(rig.board.text == "transcript")
        await rig.time.advance(to: receiptCapMs)
        #expect(rig.board.text == "user clipboard")
    }

    @Test func aLateConfirmationOfAnOlderPasteIsIgnored() async {
        let rig = Rig()
        #expect(rig.session.paste("one", keyCode: 9, targetPID: 1, holdForField: true))
        let first = rig.session.pasteGeneration
        #expect(rig.session.paste("two", keyCode: 9, targetPID: 1, holdForField: true))
        rig.session.fieldShowedPaste(generation: first)
        await rig.time.advance(to: 1_000)
        #expect(rig.board.text == "two")
        #expect(rig.board.snapshots == 1)
    }

    @Test func aCopyDuringAHeldPasteWins() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        rig.board.externalCopy("user copied this")
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        await rig.time.advance(to: receiptCapMs + 1_000)
        #expect(rig.board.text == "user copied this")
    }

    @Test func terminationLiftsTheHoldAndRestoresAtOnce() async {
        let rig = Rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        await rig.read(at: 50)
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "transcript")
        rig.session.restoreForTermination()
        #expect(rig.board.text == "user clipboard")
        #expect(!rig.session.isRestorePending)
    }

    @Test func thePartsOfALongPasteShareTheSnapshotTakenBeforeTheFirst() async {
        let rig = Rig()
        rig.session.beginBatch()
        #expect(rig.session.paste("one", keyCode: 9, targetPID: 1))
        await rig.read(at: 5)
        #expect(rig.session.paste("two", keyCode: 9, targetPID: 1))
        await rig.read(at: 40)
        #expect(rig.board.snapshots == 1)
        rig.session.finishBatch()
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "user clipboard")
    }
}

/// The clipboard held only a file promise, so there is nothing to put back. The lease still runs its course.
@MainActor @Suite struct PromiseOnlyLeaseTests {
    private func rig() -> Rig {
        let rig = Rig()
        rig.board.contents = PasteboardSnapshot(items: [], droppedFilePromise: true)
        return rig
    }

    @Test func theLeaseRunsAndTheTranscriptStays() async {
        let rig = rig()
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1, holdForField: true))
        #expect(rig.session.transcriptStays)
        #expect(!rig.session.isRestorePending)
        #expect(rig.session.holdsPaste(rig.session.pasteGeneration))
        await rig.read(at: 30)
        await rig.time.advance(to: 150)
        rig.session.fieldShowedPaste(generation: rig.session.pasteGeneration)
        await rig.time.advance(to: 230)
        #expect(!rig.session.holdsPaste(rig.session.pasteGeneration))
        #expect(rig.session.wasRestored(rig.session.pasteGeneration))
        #expect(!rig.session.transcriptStays)
        #expect(rig.board.text == "transcript")
        #expect(!rig.board.contents.droppedFilePromise)
        // Real data, kept out of history, not the promise that dies with the app.
        #expect(!rig.board.lastWasPromise)
        #expect(rig.board.lastMarkers == PasteboardSession.concealedMarkers)
    }

    @Test func aLongPasteAdvancesOnEachReceiptAndLeavesTheLastPart() async {
        let rig = rig()
        rig.session.beginBatch()
        #expect(rig.session.paste("one", keyCode: 9, targetPID: 1))
        let first = rig.session.pasteGeneration
        await rig.read(at: 10)
        #expect(rig.session.holdsPaste(first) && rig.session.readCount == 1)
        #expect(rig.session.paste("two", keyCode: 9, targetPID: 1))
        #expect(rig.session.holdsPaste(rig.session.pasteGeneration) && rig.session.transcriptStays)
        #expect(rig.board.snapshots == 1)
        await rig.read(at: 40)
        rig.session.finishBatch()
        await rig.time.advance(to: 300)
        #expect(rig.board.text == "two")
        #expect(!rig.session.isRestorePending && !rig.session.holdsPaste(rig.session.pasteGeneration))
    }

    @Test func anEmptyClipboardIsStillGivenBackEmpty() async {
        let rig = Rig()
        rig.board.contents = PasteboardSnapshot(items: [])
        #expect(rig.session.paste("transcript", keyCode: 9, targetPID: 1))
        #expect(rig.session.isRestorePending && !rig.session.transcriptStays)
        await rig.read(at: 30)
        await rig.time.advance(to: 230)
        #expect(rig.board.contents == PasteboardSnapshot(items: []))
    }
}

@MainActor @Suite struct FilePromiseClipboardTests {
    private static let promiseTypes = SystemPasteboard.filePromiseTypes.map { NSPasteboard.PasteboardType($0) }
    private static let metadata = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
    private static let contentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")

    /// Stands in for the copying app: counts how often the pasteboard asks it for the promise's types.
    private final class Provider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.withLock { count += 1 }
            item.setString("public.png", forType: type)
        }
    }

    private final class FileDelegate: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "promised.png" }
        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Keys: PasteEventPosting {
        func postPaste(keyCode: CGKeyCode, targetPID: pid_t?) -> Bool { true }
    }

    private func seedPromise(_ board: NSPasteboard, provider: Provider, alongside extra: [NSPasteboardItem] = []) {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [Self.metadata, Self.contentType])
        board.writeObjects([item] + extra)
    }

    private func hasPromiseType(_ board: NSPasteboard) -> Bool {
        (board.pasteboardItems ?? []).contains { item in item.types.contains { Self.promiseTypes.contains($0) } }
    }

    @Test func aPromiseOnlyClipboardSnapshotsAsNothingWithoutBeingRead() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = Provider()
        seedPromise(board, provider: provider)
        let snapshot = SystemPasteboard(board).snapshot()
        #expect(snapshot.items.isEmpty && snapshot.droppedFilePromise)
        #expect(provider.calls == 0)
    }

    @Test func whatTheSystemsOwnFilePromiseWritesIsRecognised() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let delegate = FileDelegate()
        board.writeObjects([NSFilePromiseProvider(fileType: "public.png", delegate: delegate)])
        #expect(hasPromiseType(board))
        let snapshot = SystemPasteboard(board).snapshot()
        #expect(snapshot.items.isEmpty && snapshot.droppedFilePromise)
    }

    @Test func thePictureRidingWithAPromiseComesBackWithoutThePromise() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = Provider()
        let picture = NSPasteboardItem()
        picture.setData(Data([0x4D, 0x4D, 0, 42]), forType: .tiff)
        seedPromise(board, provider: provider, alongside: [picture])
        let access = SystemPasteboard(board)
        let snapshot = access.snapshot()
        #expect(snapshot.droppedFilePromise)
        #expect(snapshot.items.map { $0.map(\.type) } == [[NSPasteboard.PasteboardType.tiff.rawValue]])
        #expect(provider.calls == 0)
        access.restore(snapshot)
        #expect(board.data(forType: .tiff) == Data([0x4D, 0x4D, 0, 42]))
        #expect(!hasPromiseType(board))
    }

    @Test func textOnTheSameItemAsAPromiseComesBackWithoutThePromise() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = Provider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [Self.metadata, Self.contentType])
        item.setString("promised.png", forType: .string)
        board.writeObjects([item])
        let access = SystemPasteboard(board)
        let snapshot = access.snapshot()
        #expect(snapshot.droppedFilePromise)
        #expect(snapshot.items.map { $0.map(\.type) } == [[NSPasteboard.PasteboardType.string.rawValue]])
        #expect(provider.calls == 0)
        access.restore(snapshot)
        #expect(board.string(forType: .string) == "promised.png")
        #expect(!hasPromiseType(board))
    }

    @Test func fileURLsAndImagesAreNotPromises() {
        let files = NSPasteboard.withUniqueName()
        defer { files.releaseGlobally() }
        files.writeObjects([URL(fileURLWithPath: "/tmp/promised.png") as NSURL])
        files.setString("promised.png", forType: .string)
        let fileSnapshot = SystemPasteboard(files).snapshot()
        #expect(!fileSnapshot.droppedFilePromise && fileSnapshot.items.count == 1)
        #expect(fileSnapshot.items[0].contains { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue })

        let image = NSPasteboard.withUniqueName()
        defer { image.releaseGlobally() }
        image.setData(Data([0x4D, 0x4D, 0, 42]), forType: .tiff)
        let imageSnapshot = SystemPasteboard(image).snapshot()
        #expect(!imageSnapshot.droppedFilePromise && imageSnapshot.items.count == 1)

        let text = NSPasteboard.withUniqueName()
        defer { text.releaseGlobally() }
        text.setString("just text", forType: .string)
        #expect(!SystemPasteboard(text).snapshot().droppedFilePromise)
    }

    @Test func aPasteOverAPromiseOnlyClipboardLeavesTheTranscriptAndEndsTheLease() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = Provider()
        seedPromise(board, provider: provider)
        var scheduled: [@MainActor () -> Void] = []
        let session = PasteboardSession(pasteboard: SystemPasteboard(board), poster: Keys(), schedule: { _, work in scheduled.append(work) })

        #expect(session.paste("Dictated", keyCode: 9, targetPID: 1))
        #expect(!session.isRestorePending && session.transcriptStays)
        #expect(session.holdsPaste(session.pasteGeneration))
        #expect(provider.calls == 0)
        // The target's read.
        #expect(board.string(forType: .string) == "Dictated")
        await Task.yield()
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        #expect(!session.holdsPaste(session.pasteGeneration) && session.wasRestored(session.pasteGeneration))
        // The transcript stays; a dead promise is not republished.
        #expect(board.string(forType: .string) == "Dictated")
        #expect(!hasPromiseType(board))
    }

    @Test func aPlainClipboardIsStillLeasedAndRestored() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("mine", forType: .string)
        var scheduled: [@MainActor () -> Void] = []
        let session = PasteboardSession(pasteboard: SystemPasteboard(board), poster: Keys(), schedule: { _, work in scheduled.append(work) })

        #expect(session.paste("Dictated", keyCode: 9, targetPID: 1))
        #expect(session.isRestorePending && !session.transcriptStays)
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        #expect(board.string(forType: .string) == "mine")
    }
}
