import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var all: [String] { lock.withLock { entries } }
    func index(of entry: String) -> Int? { all.firstIndex(of: entry) }
    func contains(_ entry: String) -> Bool { all.contains(entry) }
}

private struct Boom: Error {}

@MainActor
private final class FakeCapture: DictationCapturing {
    let log: CallLog
    var isPrepared = true
    var startError: Error?
    var stopError: Error?
    var audio: CapturedAudio
    var keyDownAtNanos: UInt64?

    init(log: CallLog, audio: CapturedAudio) {
        self.log = log
        self.audio = audio
    }

    func start(keyDownAtNanos: UInt64) async throws {
        log.add("capture.start")
        self.keyDownAtNanos = keyDownAtNanos
        if let startError { throw startError }
    }

    func stop() async throws -> CapturedAudio {
        log.add("capture.stop")
        if let stopError { throw stopError }
        return audio
    }

    func cancel() async { log.add("capture.cancel") }
}

@MainActor
private final class FakeEngine: DictationEngine {
    let log: CallLog
    var readiness = EngineReadiness.ready
    var error: Error?
    var result = Transcription(
        text: "Hello world.",
        words: [
            WordTiming(word: "Hello", start: 0.1, end: 0.4, confidence: 0.9),
            WordTiming(word: "world.", start: 0.5, end: 0.9, confidence: 0.8),
        ],
        processingSeconds: 0.2, engineID: "fake"
    )
    var samplesSeen: [Int] = []

    init(log: CallLog) {
        self.log = log
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        log.add("engine.transcribe")
        samplesSeen.append(samples.count)
        if let error { throw error }
        return result
    }
}

private final class FakeStore: DictationStoring, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    var failing: Set<String> = []
    private(set) var start: DictationStart?
    private(set) var capture: CaptureRecord?
    private(set) var transcription: TranscriptionRecord?
    private(set) var insertion: InsertionRecord?
    private(set) var handsFreeLock: (DictationMode, DictationTrigger)?
    private(set) var finishes: [(DictationStatus, String?)] = []
    private(set) var reopens = 0
    private(set) var edits: [EditOp] = []

    init(log: CallLog) {
        self.log = log
    }

    private func run(_ name: String, _ body: () -> Void) throws {
        log.add("store.\(name)")
        if failing.contains(name) { throw Boom() }
        lock.withLock { body() }
    }

    func begin(_ start: DictationStart) async throws { try run("begin") { self.start = start } }
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws { try run("recordCapture") { capture = record } }
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws {
        try run("recordTranscription") { transcription = record }
    }
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws { try run("recordInsertion") { insertion = record } }
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws {
        try run("recordLock") { handsFreeLock = (mode, trigger) }
    }
    func reopen(_ id: String) async throws { try run("reopen") { reopens += 1 } }
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws { try run("appendEdits") { self.edits += edits } }
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {
        try run("finish") { finishes.append((status, errorMessage)) }
    }
}

private struct FakeArchive: DictationArchiving {
    let log: CallLog

    func archive(samples: [Float], id: String) throws -> URL {
        log.add("archive.write")
        return URL(fileURLWithPath: "/tmp/audio/\(id).wav")
    }
}

@MainActor
private final class FakeInserter: DictationInserting {
    let log: CallLog
    var result = DeliveryResult(method: .paste, outcome: .unknown, focusMoved: false, target: nil, finalText: "Hello world.")
    var delivered: [String] = []
    var startFocusSeen: FocusSnapshot?
    var context: InsertionContext?
    var clipboard: String?
    private(set) var contextReads = 0
    private(set) var clipboardReads = 0

    init(log: CallLog) {
        self.log = log
    }

    func snapshotFocus() -> FocusSnapshot {
        log.add("inserter.snapshot")
        return FocusSnapshot(pid: 7, bundleID: "com.apple.Notes", appName: "Notes", role: "AXTextArea")
    }

    func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult {
        log.add("inserter.deliver")
        delivered.append(text)
        startFocusSeen = startFocus
        return result
    }

    func insertionContext() -> InsertionContext? {
        contextReads += 1
        return context
    }

    func clipboardText() -> String? {
        clipboardReads += 1
        return clipboard
    }
}

private struct FakeVocabulary: VocabularyProviding {
    var rules: [DictionaryRule] = []
    var expansions: [Snippet] = []
    func dictionary() -> [DictionaryRule] { rules }
    func snippets() -> [Snippet] { expansions }
}

private struct SlowNumbers: NumberFormatting {
    func spans(in text: String) -> [TextSpan] {
        Thread.sleep(forTimeInterval: 0.08)
        return []
    }
}

@MainActor
private final class FakePill: DictationPill {
    let log: CallLog
    var messages: [PillMessage] = []
    var notices: [String] = []

    init(log: CallLog) {
        self.log = log
    }

    func showRecording() { log.add("pill.recording") }
    func showHandsFree() { log.add("pill.handsFree") }
    func showHandsFreeNotice(_ text: String, duration: TimeInterval) {
        notices.append(text)
        log.add("pill.notice:\(text)")
    }
    func showProcessing() { log.add("pill.processing") }
    func showMessage(_ message: PillMessage, duration: TimeInterval) {
        messages.append(message)
        log.add("pill.message:\(message.headline)")
    }
    func hide() { log.add("pill.hide") }
}

@MainActor
private final class FakeCards: DictationCards {
    let log: CallLog
    var presented: [DeliveryCard] = []
    var onUndo: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?

    init(log: CallLog) {
        self.log = log
    }

    func present(_ card: DeliveryCard) {
        presented.append(card)
        log.add("card.present:\(card.kind)")
    }

    func dismiss() { log.add("card.dismiss") }
}

@MainActor
private final class FakeSounds: SoundPlayer {
    let log: CallLog

    init(log: CallLog) {
        self.log = log
    }

    func playStart() { log.add("sound.start") }
    func playStop() { log.add("sound.stop") }
    func playLock() { log.add("sound.lock") }
    func playError() { log.add("sound.error") }
}

final class FakeClock: DictationClock, @unchecked Sendable {
    static let wall = Date(timeIntervalSince1970: 1_791_806_400)
    private let lock = NSLock()
    private var host: UInt64
    private var elapsed: TimeInterval = 0
    private var nextSleeper = 0
    private var sleepers: [Int: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelledSleepers: Set<Int> = []

    /// Host time here is nanoseconds; every read moves 100 ms on.
    init(start: UInt64) {
        host = start
    }

    func nowNanos() -> UInt64 {
        lock.withLock {
            host += 100_000_000
            return host
        }
    }

    func milliseconds(from start: UInt64, to end: UInt64) -> Int { Int(max(end, start) - start) / 1_000_000 }
    func now() -> Date { Self.wall }
    func date(atNanos nanos: UInt64) -> Date { Self.wall }

    func sleep(forSeconds seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            nextSleeper += 1
            return nextSleeper
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelledSleepers.contains(id) { return true }
                    sleepers[id] = (elapsed + seconds, continuation)
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancelledSleepers.insert(id)
                return sleepers.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Moves the sleep clock on and wakes every sleeper whose time has come.
    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            elapsed += seconds
            let ready = sleepers.filter { $0.value.deadline <= elapsed }.sorted { $0.value.deadline < $1.value.deadline }
            ready.forEach { sleepers[$0.key] = nil }
            return ready.map(\.value.continuation)
        }
        due.forEach { $0.resume() }
    }
}

private let keyDown: UInt64 = 5_000_000_000
private let keyUp: UInt64 = 7_000_000_000

/// A short tone, 0.5 s silence, then 1 s tone, so the first word is not head-trimmed.
private func capturedWithLeadingCue() -> CapturedAudio {
    var samples = (0..<1_600).map { 0.3 * sin(Float($0) * 0.2) }
    samples += [Float](repeating: 0, count: 8_000)
    samples += (0..<16_000).map { 0.3 * sin(Float($0) * 0.2) }
    return CapturedAudio(
        samples: samples, sampleRate: 16_000, deviceUID: "uid", deviceName: "Test Mic", deviceTransport: "built-in",
        firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 1_700
    )
}

/// 0.5 s silence, 1 s tone, 0.5 s silence at 16 kHz.
private func capturedTone() -> CapturedAudio {
    var samples = [Float](repeating: 0, count: 8_000)
    samples += (0..<16_000).map { 0.3 * sin(Float($0) * 0.2) }
    samples += [Float](repeating: 0, count: 8_000)
    return CapturedAudio(
        samples: samples, sampleRate: 16_000, deviceUID: "uid", deviceName: "Test Mic", deviceTransport: "built-in",
        firstSampleMs: 30, firstNonzeroMs: 45, captureStartMs: 12, audioMs: 2_000
    )
}

@MainActor
private struct Rig {
    let log = CallLog()
    let capture: FakeCapture
    let engine: FakeEngine
    let store: FakeStore
    let inserter: FakeInserter
    let pill: FakePill
    let sounds: FakeSounds
    let cards: FakeCards
    let controller: DictationController
    let clock: FakeClock
    var finishedAttempts: Counter
    let handsFreeChanges = Counter()

    final class Counter {
        var count = 0
    }

    init(
        audio: CapturedAudio = capturedTone(), withStore: Bool = true, settings: CleanupSettings = CleanupSettings(),
        vocabulary: FakeVocabulary = FakeVocabulary(), textPipeline: TextPipeline = TextPipeline()
    ) {
        capture = FakeCapture(log: log, audio: audio)
        engine = FakeEngine(log: log)
        store = FakeStore(log: log)
        inserter = FakeInserter(log: log)
        pill = FakePill(log: log)
        sounds = FakeSounds(log: log)
        cards = FakeCards(log: log)
        let clock = FakeClock(start: keyUp)
        self.clock = clock
        var pipeline = DictationPipeline(
            store: withStore ? store : nil, archive: FakeArchive(log: log), engine: engine, clock: clock
        )
        pipeline.settings = { settings }
        pipeline.vocabulary = vocabulary
        pipeline.textPipeline = textPipeline
        controller = DictationController(
            capture: capture, engine: engine, pipeline: pipeline, inserter: inserter, pill: pill, sounds: sounds, clock: clock,
            cards: cards
        )
        let counter = Counter()
        finishedAttempts = counter
        controller.onAttemptFinished = { counter.count += 1 }
        let changes = handsFreeChanges
        controller.onHandsFreeChanged = { active in changes.count += active ? 1 : 100 }
        let ended = lockEnded
        controller.onLockEnded = { ended.count += 1 }
    }

    let lockEnded = Counter()

    /// Lets tasks the controller started on the main actor run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func lockIn(_ trigger: LockTrigger = .doubleTap) async {
        await controller.handle(.pressed(at: keyDown))
        await controller.handle(.locked(at: keyDown + 300_000_000, trigger: trigger))
        await settle()
    }

    func dictate() async {
        await controller.handle(.pressed(at: keyDown))
        await controller.handle(.released(at: keyUp))
        await controller.waitForProcessing()
    }
}

@MainActor
@Suite struct DictationCleanupTests {
    private let messy = "um so the build is uh green new line ship it"
    private let cleaned = "So the build is green\nShip it"

    @Test func theCleanedTextIsDeliveredAndStored() async throws {
        let rig = Rig()
        rig.engine.result.text = messy
        await rig.dictate()

        #expect(rig.inserter.delivered == [cleaned])
        #expect(rig.store.transcription?.rawText == messy)
        let insertion = try #require(rig.store.insertion)
        #expect(insertion.detText == cleaned)
        #expect(insertion.cleanup?.cleanerID == "deterministic" && insertion.cleanup?.outcome == "ok")
        #expect(insertion.cleanup?.style == "formal" && insertion.cleanup?.ms != nil)
        #expect(rig.store.edits.contains { $0.stage == "filler" })
        #expect(rig.store.edits.contains { $0.stage == "spoken command" })
        let insertAt = try #require(rig.log.index(of: "store.recordInsertion"))
        let editsAt = try #require(rig.log.index(of: "store.appendEdits"))
        #expect(editsAt > insertAt)
    }

    @Test func listCommandsReachThePaste() async {
        let rig = Rig()
        rig.engine.result.text = "shopping list colon bullet milk bullet eggs"
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Shopping list:\n- Milk\n- Eggs"])
    }

    @Test func theMasterSwitchOffDeliversTheRawText() async throws {
        var off = CleanupSettings()
        off.enabled = false
        let rig = Rig(settings: off)
        rig.engine.result.text = messy
        await rig.dictate()

        #expect(rig.inserter.delivered == [messy])
        let insertion = try #require(rig.store.insertion)
        #expect(insertion.detText == messy && insertion.cleanup?.outcome == "skipped")
        #expect(rig.store.edits.isEmpty && !rig.log.contains("store.appendEdits"))
        #expect(rig.inserter.contextReads == 0)
    }

    @Test func perStageSwitchesApply() async {
        var settings = CleanupSettings()
        settings.fillers = false
        let rig = Rig(settings: settings)
        rig.engine.result.text = "um hello"
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Um hello"])
    }

    @Test func theStyleSettingReachesTheText() async throws {
        var settings = CleanupSettings()
        settings.style = StylePreset.casual.options
        let rig = Rig(settings: settings)
        rig.engine.result.text = "See you Friday."
        await rig.dictate()
        #expect(rig.inserter.delivered == ["See you Friday"])
        #expect(rig.store.insertion?.cleanup?.style == "casual")
    }

    @Test func theCursorContextBlendsTheText() async {
        let rig = Rig()
        rig.inserter.context = InsertionContext(before: "I think", after: nil)
        rig.engine.result.text = "The build is green."
        await rig.dictate()
        #expect(rig.inserter.delivered == ["the build is green."])
        #expect(rig.inserter.contextReads == 1)
    }

    @Test func theClipboardIsReadOnlyForSnippetsThatUseIt() async {
        let plain = Rig()
        await plain.dictate()
        #expect(plain.inserter.clipboardReads == 0)

        let rig = Rig(vocabulary: FakeVocabulary(expansions: [Snippet(trigger: "paste it", expansion: "Link: {clipboard}")]))
        rig.inserter.clipboard = "https://example.com"
        rig.engine.result.text = "paste it"
        await rig.dictate()
        #expect(rig.inserter.clipboardReads == 1)
        #expect(rig.inserter.delivered == ["Link: https://example.com"])
    }

    @Test func theDictionaryComesFromTheVocabularySeam() async {
        let rig = Rig(vocabulary: FakeVocabulary(rules: [DictionaryRule(heard: "mouth type", written: "Mouthtype")]))
        rig.engine.result.text = "send it to mouth type"
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Send it to Mouthtype"])
    }

    @Test func slowCleanupFallsBackToTheRawText() async throws {
        let rig = Rig(textPipeline: TextPipeline(numberFormatter: SlowNumbers()))
        rig.engine.result.text = messy
        await rig.dictate()
        #expect(rig.inserter.delivered == [messy])
        #expect(rig.store.insertion?.cleanup?.outcome == "timeout")
        #expect(rig.store.insertion?.detText == messy)
    }

    @Test func aDictationOfOnlyFillersEndsAsEmpty() async {
        let rig = Rig()
        rig.engine.result.text = "um uh"
        await rig.dictate()
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(rig.store.insertion == nil)
        #expect(rig.log.all.last == "pill.hide")
    }

    @Test func aBlankAudioTagEndsAsEmpty() async {
        let rig = Rig()
        rig.engine.result.text = "[BLANK_AUDIO]"
        await rig.dictate()
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(rig.store.edits.map(\.stage) == ["filler"])
    }

    @Test func aLeadingStartCueIsDropped() async throws {
        let rig = Rig(audio: capturedWithLeadingCue())
        rig.engine.result = Transcription(
            text: "Tink Send it",
            words: [
                WordTiming(word: "Tink", start: 0.05, end: 0.1, confidence: 0.2),
                WordTiming(word: "Send", start: 0.7, end: 0.9, confidence: 0.95),
                WordTiming(word: "it", start: 0.9, end: 1.0, confidence: 0.95),
            ],
            processingSeconds: 0.2, engineID: "fake"
        )
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Send it"])
        #expect(rig.store.transcription?.rawText == "Tink Send it")
        #expect(rig.store.edits.first?.fromText == "Tink" && rig.store.edits.first?.stage == "filler")
    }

    @Test func undoDeliversTheCleanedText() async {
        let rig = Rig()
        rig.engine.result.text = messy
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.settle()
        await rig.controller.undoCancel()
        #expect(rig.inserter.delivered == [cleaned])
        #expect(rig.store.insertion?.detText == cleaned)
    }

    @Test func theCardShowsTheCleanedText() async {
        let rig = Rig()
        rig.engine.result.text = messy
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        await rig.dictate()
        #expect(rig.cards.presented == [.secure(cleaned)])
    }
}

@MainActor
@Suite struct DictationControllerTests {
    @Test func happyPathRunsTheCollaboratorsInOrder() async throws {
        let rig = Rig()
        await rig.dictate()

        #expect(rig.log.all == [
            "card.dismiss", "inserter.snapshot", "capture.start", "sound.start", "pill.recording", "store.begin",
            "capture.stop", "sound.stop", "pill.processing",
            "archive.write", "store.recordCapture", "engine.transcribe", "store.recordTranscription",
            "inserter.deliver", "store.recordInsertion", "pill.hide",
        ])
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 1)
        #expect(rig.capture.keyDownAtNanos == keyDown)
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.inserter.startFocusSeen?.bundleID == "com.apple.Notes")
    }

    @Test func happyPathWritesTheRightValues() async throws {
        let rig = Rig()
        await rig.dictate()

        let start = try #require(rig.store.start)
        #expect(start.mode == .hold && start.trigger == .fn)
        #expect(start.target.bundleID == "com.apple.Notes" && start.target.appName == "Notes" && start.target.fieldRole == "AXTextArea")
        #expect(start.startedAt == FakeClock.wall)
        #expect(start.osVersion?.isEmpty == false)

        let capture = try #require(rig.store.capture)
        #expect(capture.keyUpMs == 2_000)
        #expect(capture.captureStartMs == 12 && capture.firstSampleMs == 30 && capture.firstNonzeroMs == 45)
        #expect(capture.audioMs == 2_000 && capture.sampleRateHz == 16_000)
        #expect(capture.inputDeviceName == "Test Mic" && capture.inputTransport == "built-in")
        #expect(capture.audioPath?.hasSuffix("\(start.id).wav") == true)
        #expect(capture.audioExpiresAt == FakeClock.wall.addingTimeInterval(90 * 24 * 3600))
        #expect((capture.voicedMs ?? 0) > 500)
        #expect(capture.peakDb != nil && capture.rmsDb != nil && capture.noiseFloorDb != nil)

        let transcription = try #require(rig.store.transcription)
        #expect(transcription.rawText == "Hello world.")
        let asrDone = try #require(transcription.asrDoneMs)
        let insertDone = try #require(rig.store.insertion?.insertDoneMs)
        #expect(asrDone > 2_000 && insertDone > asrDone)

        let insertion = try #require(rig.store.insertion)
        #expect(insertion.finalText == "Hello world.")
        #expect(insertion.method == "paste" && insertion.outcome == "unknown" && insertion.focusMoved == false)
        #expect(rig.store.finishes.isEmpty)
    }

    @Test func wordTimingsAreShiftedByTheHeadTrim() async throws {
        let rig = Rig()
        await rig.dictate()

        // 0.5 s of leading silence minus the 0.25 s margin leaves 250 ms cut from the head.
        let record = try #require(rig.store.transcription)
        let words = record.transcription.words
        #expect(words.count == 2)
        #expect(abs(words[0].start - 0.35) < 0.001 && abs(words[0].end - 0.65) < 0.001)
        #expect(abs(words[1].start - 0.75) < 0.001 && abs(words[1].end - 1.15) < 0.001)
        #expect(record.speechOnsetMs == 380)
        // The engine got the trimmed audio, not the whole capture.
        #expect((rig.engine.samplesSeen.first ?? 0) < 32_000)
    }

    @Test func shortTapDiscardsQuietly() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.discarded(reason: .tooShort))

        #expect(rig.log.contains("capture.cancel"))
        #expect(rig.store.finishes.map(\.0) == [.tooShort])
        #expect(rig.log.all.last == "pill.hide")
        #expect(!rig.log.contains("sound.stop") && !rig.log.contains("sound.error"))
        #expect(rig.pill.messages.isEmpty)
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 1)
    }

    @Test func escapeCancelsKeepsTheAudioAndOffersUndo() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))

        // Stopped, not cancelled: the audio stays in memory for Undo.
        #expect(rig.log.contains("capture.stop") && !rig.log.contains("capture.cancel"))
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.cards.presented.map(\.kind) == [.cancelled])
        let card = rig.cards.presented.first
        #expect(card?.header == "Cancelled" && card?.transcript == nil)
        #expect(card?.actions == [.undo] && card?.countdown == 5)
        #expect(rig.pill.messages.isEmpty && rig.log.contains("pill.hide"))
        #expect(!rig.log.contains("engine.transcribe") && !rig.log.contains("archive.write"))
        #expect(rig.controller.phase == .idle)
    }

    @Test func undoWithinTheWindowTranscribesDeliversAndFixesTheRow() async throws {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.settle()
        #expect(rig.clock.sleeperCount == 1)

        rig.clock.advance(by: 4.9)
        await rig.settle()
        await rig.controller.undoCancel()

        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.store.reopens == 1)
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.store.insertion?.finalText == "Hello world.")
        let tail = Array(rig.log.all.drop { $0 != "store.reopen" })
        #expect(tail == [
            "store.reopen", "pill.processing", "archive.write", "store.recordCapture", "engine.transcribe",
            "store.recordTranscription", "inserter.deliver", "store.recordInsertion", "pill.hide",
        ])
        #expect(rig.controller.phase == .idle && rig.clock.sleeperCount == 0)

        // The expiry timer is gone: running the clock out dismisses nothing more.
        let dismissals = rig.log.all.filter { $0 == "card.dismiss" }.count
        rig.clock.advance(by: 10)
        await rig.settle()
        #expect(rig.log.all.filter { $0 == "card.dismiss" }.count == dismissals)
    }

    @Test func undoDeliversToACardWhenThePasteCannotLand() async {
        let rig = Rig()
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: true, target: nil, finalText: "")
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.controller.undoCancel()
        #expect(rig.cards.presented.map(\.kind) == [.cancelled, .secure])
    }

    @Test func theWindowLapsingDiscardsTheAudio() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.settle()
        rig.clock.advance(by: 5)
        await rig.settle()

        #expect(rig.log.all.last == "card.dismiss")
        await rig.controller.undoCancel()
        #expect(!rig.log.contains("engine.transcribe") && rig.store.reopens == 0)
        #expect(rig.inserter.delivered.isEmpty)
    }

    @Test func aNewPressDismissesTheCardAndDiscardsTheAudio() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.settle()
        await rig.controller.handle(.pressed(at: keyDown + 1_000_000_000))
        #expect(rig.log.contains("card.dismiss"))
        #expect(rig.clock.sleeperCount == 0)

        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        await rig.controller.undoCancel()
        #expect(rig.log.all.filter { $0 == "engine.transcribe" }.count == 1)
        #expect(rig.store.reopens == 0)
    }

    @Test func dismissingTheCancelledCardDiscardsTheAudio() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        rig.cards.onDismissed?(.cancelled())
        await rig.settle()
        #expect(rig.clock.sleeperCount == 0)
        await rig.controller.undoCancel()
        #expect(!rig.log.contains("engine.transcribe"))
    }

    @Test func aStoppedCaptureThatErrorsFallsBackToAPlainCancel() async {
        let rig = Rig()
        rig.capture.stopError = CaptureError.notRecording
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        #expect(rig.log.contains("capture.cancel"))
        #expect(rig.cards.presented.isEmpty)
        #expect(rig.pill.messages == [PillMessage("Cancelled")])
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
    }

    @Test func pressWhileTheEngineLoadsOnlyShowsAMessage() async {
        let rig = Rig()
        rig.engine.readiness = .loading
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.log.all == ["pill.message:Loading model"])
        #expect(rig.pill.messages == [PillMessage("Loading model", detail: "Try again in a moment")])
        #expect(rig.controller.phase == .idle)

        await rig.controller.handle(.released(at: keyUp))
        #expect(rig.log.all.count == 1)
    }

    @Test func pressWithoutMicrophoneAccessOnlyShowsAMessage() async {
        let rig = Rig()
        rig.capture.isPrepared = false
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.log.all == ["pill.message:Microphone access needed"])
        #expect(rig.controller.phase == .idle)
    }

    @Test func pressWhileProcessingIsIgnored() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        #expect(rig.controller.phase == .processing)

        await rig.controller.handle(.pressed(at: keyUp + 1))
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        #expect(rig.pill.messages == [PillMessage("Still working", detail: "Finishing the last dictation")])

        await rig.controller.waitForProcessing()
        #expect(rig.controller.phase == .idle)
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.finishedAttempts.count == 1)
    }

    @Test func eventsOutOfOrderAreIgnored() async {
        let rig = Rig()
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.handle(.discarded(reason: .tooShort))
        await rig.controller.handle(.cancelled(reason: .escape))
        #expect(rig.log.all.isEmpty)

        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.pressed(at: keyDown + 1))
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        #expect(rig.controller.phase == .recording)
    }

    @Test func captureErrorEndsFailedAndReturnsToIdle() async {
        let rig = Rig()
        rig.capture.startError = CaptureError.noInputDevice
        await rig.controller.handle(.pressed(at: keyDown))

        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.store.finishes.first?.1?.isEmpty == false)
        #expect(rig.pill.messages == [PillMessage("No microphone found", detail: "Connect one and try again", isError: true)])
        #expect(rig.log.contains("sound.error") && !rig.log.contains("pill.recording"))
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 1)

        rig.capture.startError = nil
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
    }

    @Test func captureStopErrorEndsFailed() async {
        let rig = Rig()
        rig.capture.stopError = CaptureError.routeChanged
        await rig.dictate()
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.pill.messages == [PillMessage("Microphone changed", detail: "Try again", isError: true)])
        #expect(rig.controller.phase == .idle)
    }

    @Test func engineErrorEndsFailedAndReturnsToIdle() async {
        let rig = Rig()
        rig.engine.error = Boom()
        await rig.dictate()

        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.pill.messages == [PillMessage("Transcription failed", detail: "Try again", isError: true)])
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.controller.phase == .idle)

        rig.engine.error = nil
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
    }

    @Test func storeFailureNeverStopsDelivery() async {
        let rig = Rig()
        rig.store.failing = ["begin", "recordCapture", "recordTranscription", "recordInsertion"]
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.log.contains("pill.hide"))
        #expect(rig.controller.phase == .idle)
        // The row never opened, so only the failed begin was attempted.
        #expect(rig.log.all.filter { $0.hasPrefix("store.") } == ["store.begin"])
    }

    @Test func aFailingWriteMidwayStillDelivers() async {
        let rig = Rig()
        rig.store.failing = ["recordCapture", "recordTranscription"]
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.store.insertion?.finalText == "Hello world.")
    }

    @Test func noStoreStillDictates() async {
        let rig = Rig(withStore: false)
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(!rig.log.all.contains { $0.hasPrefix("store.") })
    }

    @Test func emptyTranscriptionFinishesEmptyWithoutPasting() async throws {
        let rig = Rig()
        rig.engine.result = Transcription(text: "", processingSeconds: 0.1, engineID: "fake")
        await rig.dictate()

        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(rig.store.transcription?.rawText == "")
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.log.all.last == "pill.hide")
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 1)
    }

    @Test func silenceNeverReachesTheEngine() async {
        let rig = Rig(audio: CapturedAudio(
            samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, deviceUID: nil, deviceName: nil,
            deviceTransport: "built-in", firstSampleMs: 20, firstNonzeroMs: nil, captureStartMs: 10, audioMs: 1_000
        ))
        await rig.dictate()

        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(!rig.log.contains("engine.transcribe"))
        #expect(rig.log.contains("archive.write"))
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.pill.messages.isEmpty)
    }

    @Test func eachDeliveryOutcomeMapsToTheRightCard() async {
        let cases: [(DeliveryResult.Method, DeliveryResult.Outcome, String, DeliveryCard.Kind?, String)] = [
            (.none, .secureDiscard, "", .secure, "Secure field, not pasted"),
            (.clipboardOnly, .unknown, "Hello world.", .nowhere, "Nothing to paste into"),
            (.clipboardOnly, .failed("no event"), " Hello world.", .pasteFailed, "Paste failed"),
            (.paste, .unknown, "Hello world.", nil, ""),
        ]
        for (method, outcome, finalText, kind, header) in cases {
            let rig = Rig()
            rig.inserter.result = DeliveryResult(method: method, outcome: outcome, focusMoved: false, target: nil, finalText: finalText)
            await rig.dictate()
            #expect(rig.cards.presented.map(\.kind) == (kind.map { [$0] } ?? []))
            #expect(rig.pill.messages.isEmpty && rig.log.contains("pill.hide"))
            guard let card = rig.cards.presented.first else { continue }
            #expect(card.header == header && card.actions == [.copy] && card.countdown == nil)
            #expect(card.transcript == (finalText.isEmpty ? "Hello world." : finalText))
        }
    }

    // MARK: Hands-free

    @Test func lockRecordsModeAndTriggerCuesAndTellsThePill() async throws {
        let rig = Rig()
        await rig.lockIn(.doubleTap)

        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)
        #expect(rig.log.all == [
            "card.dismiss", "inserter.snapshot", "capture.start", "sound.start", "pill.recording", "store.begin",
            "sound.lock", "pill.handsFree", "store.recordLock",
        ])
        let lock = try #require(rig.store.handsFreeLock)
        #expect(lock.0 == .handsFree && lock.1 == .doubleTap)
        #expect(rig.handsFreeChanges.count == 1)
    }

    @Test func fnSpaceLockRecordsItsOwnTrigger() async throws {
        let rig = Rig()
        await rig.lockIn(.fnSpace)
        let lock = try #require(rig.store.handsFreeLock)
        #expect(lock.0 == .handsFree && lock.1 == .fnSpace)
    }

    @Test func stoppingALockedRecordingTranscribesAndPastesAsUsual() async throws {
        let rig = Rig()
        await rig.lockIn()
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()

        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.store.insertion?.finalText == "Hello world.")
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.log.contains("capture.stop") && rig.log.all.last == "pill.hide")
        #expect(rig.handsFreeChanges.count == 101)
        #expect(rig.lockEnded.count == 1)
        #expect(rig.finishedAttempts.count == 1)
    }

    @Test func escapeOnALockedRecordingCancels() async {
        let rig = Rig()
        await rig.lockIn()
        await rig.controller.handle(.cancelled(reason: .escape))

        #expect(rig.log.contains("capture.stop") && !rig.log.contains("engine.transcribe"))
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.cards.presented.map(\.kind) == [.cancelled])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.lockEnded.count == 1)
    }

    @Test func menuStopAndCancelActLikeTheKeyAndEscape() async {
        let stopped = Rig()
        await stopped.lockIn()
        stopped.controller.stopHandsFree()
        await stopped.controller.waitForProcessing()
        #expect(stopped.inserter.delivered == ["Hello world."])
        #expect(stopped.lockEnded.count == 1)

        let cancelled = Rig()
        await cancelled.lockIn()
        await cancelled.controller.cancelHandsFree()
        #expect(cancelled.store.finishes.map(\.0) == [.cancelled])
        #expect(cancelled.controller.phase == .idle)

        // With nothing locked both are no-ops.
        let idle = Rig()
        idle.controller.stopHandsFree()
        await idle.controller.cancelHandsFree()
        #expect(idle.log.all.isEmpty)
    }

    @Test func aLockWithNoRecordingIsRefusedAndTheHotkeySideTold() async {
        let rig = Rig()
        rig.engine.readiness = .loading
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.locked(at: keyDown + 1, trigger: .doubleTap))
        #expect(!rig.controller.isHandsFree)
        #expect(rig.lockEnded.count == 1)
        #expect(!rig.log.contains("sound.lock"))
    }

    @Test func aLockedRecordingWarnsAtNineteenMinutesAndStopsAtTwenty() async {
        let rig = Rig()
        await rig.lockIn()
        #expect(rig.clock.sleeperCount == 1)

        rig.clock.advance(by: 19 * 60 - 1)
        await rig.settle()
        #expect(rig.pill.notices.isEmpty && rig.controller.phase == .recording)

        rig.clock.advance(by: 1)
        await rig.settle()
        #expect(rig.pill.notices == ["1 minute left"])
        #expect(rig.controller.phase == .recording && rig.controller.isHandsFree)

        rig.clock.advance(by: 59)
        await rig.settle()
        #expect(rig.controller.phase == .recording)

        rig.clock.advance(by: 1)
        await rig.settle()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.lockEnded.count == 1)
    }

    @Test func stoppingEarlyCancelsTheCapTimer() async {
        let rig = Rig()
        await rig.lockIn()
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        await rig.settle()
        #expect(rig.clock.sleeperCount == 0)

        rig.clock.advance(by: 30 * 60)
        await rig.settle()
        #expect(rig.pill.notices.isEmpty)
        #expect(rig.inserter.delivered.count == 1)
    }

    @Test func tapDiscardThenSecondPressThenLockNeverLetsTheCancelKillTheNewRecording() async throws {
        let log = CallLog()
        let capture = SlowCapture(log: log, audio: capturedTone())
        let engine = FakeEngine(log: log)
        let store = FakeStore(log: log)
        let clock = FakeClock(start: keyUp)
        let controller = DictationController(
            capture: capture, engine: engine,
            pipeline: DictationPipeline(store: store, archive: FakeArchive(log: log), engine: engine, clock: clock),
            inserter: FakeInserter(log: log), pill: FakePill(log: log), sounds: FakeSounds(log: log), clock: clock,
            cards: FakeCards(log: log)
        )
        // The way the hotkey service delivers a double-tap: all four events, back to back.
        let (events, sink) = AsyncStream.makeStream(of: HotkeyEvent.self)
        sink.yield(.pressed(at: keyDown))
        sink.yield(.discarded(reason: .tooShort))
        sink.yield(.pressed(at: keyDown + 200_000_000))
        sink.yield(.locked(at: keyDown + 300_000_000, trigger: .doubleTap))
        sink.finish()
        await controller.consume(events)

        let capturing = log.all.filter { $0.hasPrefix("capture.") }
        #expect(capturing == [
            "capture.start.begin", "capture.start.end", "capture.cancel.begin", "capture.cancel.end",
            "capture.start.begin", "capture.start.end",
        ])
        #expect(capture.failures == 0)
        #expect(capture.running && capture.keyDownAtNanos == keyDown + 200_000_000)
        #expect(controller.phase == .recording && controller.isHandsFree)
        #expect(store.finishes.map(\.0) == [.tooShort])
        #expect(store.handsFreeLock?.1 == .doubleTap)
    }
}

/// A capture whose start and cancel really suspend, and that notices any overlap or a second start while running.
@MainActor
private final class SlowCapture: DictationCapturing {
    let log: CallLog
    let audio: CapturedAudio
    var isPrepared = true
    private(set) var running = false
    private(set) var busy = false
    private(set) var failures = 0
    private(set) var keyDownAtNanos: UInt64?

    init(log: CallLog, audio: CapturedAudio) {
        self.log = log
        self.audio = audio
    }

    private func work(_ name: String, _ body: () -> Void) async {
        log.add("capture.\(name).begin")
        if busy { failures += 1 }
        busy = true
        try? await Task.sleep(for: .milliseconds(30))
        body()
        busy = false
        log.add("capture.\(name).end")
    }

    func start(keyDownAtNanos: UInt64) async throws {
        await work("start") {
            if running { failures += 1 }
            running = true
            self.keyDownAtNanos = keyDownAtNanos
        }
    }

    func stop() async throws -> CapturedAudio {
        await work("stop") { running = false }
        return audio
    }

    func cancel() async {
        await work("cancel") { running = false }
    }
}
