import CoreGraphics
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
    /// What the next recordings return, in order, before `audio`.
    var audios: [CapturedAudio] = []
    var keyDownAtNanos: UInt64?
    var onInterrupted: (@MainActor () -> Void)?
    var duringStart: (@MainActor () async -> Void)?
    var duringStop: (@MainActor () async -> Void)?
    /// How many samples of the recording in progress `partialSamples` can hand over.
    var available = 0

    init(log: CallLog, audio: CapturedAudio) {
        self.log = log
        self.audio = audio
    }

    func partialSamples(from offset: Int) async -> [Float] {
        guard offset < available else { return [] }
        return [Float](repeating: 0.1, count: available - offset)
    }

    func previewSnapshot(maxSamples: Int) async -> PreviewAudio {
        PreviewAudio(samples: Array(repeating: 0.1, count: min(available, maxSamples)), capturedSampleCount: available)
    }

    /// The input goes away.
    func interrupt() { onInterrupted?() }

    func start(keyDownAtNanos: UInt64) async throws {
        log.add("capture.start")
        self.keyDownAtNanos = keyDownAtNanos
        await duringStart?()
        if let startError { throw startError }
    }

    func stop() async throws -> CapturedAudio {
        log.add("capture.stop")
        await duringStop?()
        if let stopError { throw stopError }
        return audios.isEmpty ? audio : audios.removeFirst()
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
    var previewCalls = 0
    var languages: [DictationLanguageRequest] = []
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        languages.append(language)
        return try await transcribe(samples: samples)
    }
    func preview(samples: [Float]) async throws -> String? {
        previewCalls += 1
        return "Provisional words that must not be inserted."
    }
    var samplesSeen: [Int] = []
    /// The text of the next transcriptions, in order, before `result`.
    var texts: [String] = []
    /// How many of the next transcriptions wait for `releaseHeld` before they return.
    var holds = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var heldObservers: [CheckedContinuation<Void, Never>] = []

    init(log: CallLog) {
        self.log = log
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        log.add("engine.transcribe")
        samplesSeen.append(samples.count)
        if holds > 0 {
            holds -= 1
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                let observers = heldObservers
                heldObservers = []
                observers.forEach { $0.resume() }
            }
        }
        if let error { throw error }
        guard !texts.isEmpty else { return result }
        var next = result
        next.text = texts.removeFirst()
        return next
    }

    func releaseHeld() {
        let held = waiters
        waiters = []
        held.forEach { $0.resume() }
    }

    func waitForHeld() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { heldObservers.append($0) }
    }
}

private final class SpySmart: SmartCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _levels: [CleanupLevel] = []
    var levels: [CleanupLevel] { lock.withLock { _levels } }
    private var _takes: [String] = []
    private var _released: [String] = []
    var takes: [String] { lock.withLock { _takes } }
    var released: [String] { lock.withLock { _released } }
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { nil }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { fatalError("not used") }
    func recordingStarted() {}
    func recordingStarted(level: CleanupLevel, take: String) {
        lock.withLock {
            _levels.append(level); _takes.append(take)
        }
    }
    func releasePrewarm(for take: String) { lock.withLock { _released.append(take) } }
}

private final class FakeStore: DictationStoring, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    var failing: Set<String> = []
    var duringBegin: (@MainActor @Sendable () async -> Void)?
    var duringLock: (@MainActor @Sendable () async -> Void)?
    private(set) var start: DictationStart?
    private(set) var capture: CaptureRecord?
    private(set) var transcription: TranscriptionRecord?
    private(set) var insertion: InsertionRecord?
    private(set) var verdicts: [(outcome: String, receiptMs: Int?)] = []
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

    func begin(_ start: DictationStart) async throws {
        try run("begin") { self.start = start }
        await duringBegin?()
    }
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws { try run("recordCapture") { capture = record } }
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws {
        try run("recordTranscription") { transcription = record }
    }
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws { try run("recordInsertion") { insertion = record } }
    func recordInsertVerdict(_ id: String, outcome: String, pasteReceiptMs: Int?) async throws {
        try run("recordInsertVerdict") { verdicts.append((outcome, pasteReceiptMs)) }
    }
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws {
        try run("recordLock") { handsFreeLock = (mode, trigger) }
        await duringLock?()
    }
    func reopen(_ id: String) async throws { try run("reopen") { reopens += 1 } }
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws { try run("appendEdits") { self.edits += edits } }
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {
        try run("finish") { finishes.append((status, errorMessage)) }
    }
}

private struct FakeArchive: DictationArchiving {
    let log: CallLog
    var writesPartials = false

    func archive(samples: [Float], id: String) throws -> URL {
        log.add("archive.write")
        return URL(fileURLWithPath: "/tmp/audio/\(id).wav")
    }

    func appendPartial(samples: [Float], id: String) throws { log.add("archive.partial:\(samples.count)") }
    func discardPartial(id: String) { log.add("archive.discardPartial") }
}

private final class RetryArchive: DictationArchiving, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var writes = 0
    private var saved: Set<String> = []
    var savedIDs: Set<String> { lock.withLock { saved } }
    var attempts: Int { lock.withLock { writes } }
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func archive(samples: [Float], id: String) throws -> URL {
        try lock.withLock {
            writes += 1
            if failing { throw Boom() }
            saved.insert(id)
            return URL(fileURLWithPath: "/virtual/audio/\(id).wav")
        }
    }
}

@MainActor
private final class FakeInserter: DictationInserting {
    let log: CallLog
    var result = DeliveryResult(method: .paste, outcome: .unknown, focusMoved: false, target: nil, finalText: "Hello world.")
    var delivered: [String] = []
    var startFocusSeen: FocusSnapshot?
    var focus = FocusSnapshot(pid: 7, bundleID: "com.apple.Notes", appName: "Notes", role: "AXTextArea")
    var website: String?
    /// When set, the fake page-URL read blocks on it, to stand in for a hung browser. The test signals it to let the read finish.
    var websiteGate: DispatchSemaphore?
    func websiteHostReader(for snapshot: FocusSnapshot) -> (@Sendable () -> String?)? {
        let value = website, gate = websiteGate, log = log
        return {
            log.add("inserter.website"); _ = gate?.wait(timeout: .now() + 30); return value
        }
    }
    var context: InsertionContext?
    var clipboard: String?
    private(set) var contextReads = 0
    private(set) var clipboardReads = 0
    private(set) var cancelledVerifications = 0
    private var verificationHandler: (@MainActor (PasteVerification) -> Void)?

    init(log: CallLog) {
        self.log = log
    }

    func snapshotApplication() -> FocusSnapshot {
        log.add("inserter.application")
        return FocusSnapshot(pid: focus.pid, bundleID: focus.bundleID, appName: focus.appName)
    }

    func snapshotFocus() -> FocusSnapshot {
        log.add("inserter.snapshot")
        return focus
    }

    func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult {
        log.add("inserter.deliver")
        delivered.append(text)
        startFocusSeen = startFocus
        return result
    }

    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void) { verificationHandler = handler }
    func cancelVerification() { cancelledVerifications += 1 }
    private(set) var returnsPressed: [DeliveryResult] = []
    func pressReturnAfterInsert(for result: DeliveryResult) async { returnsPressed.append(result) }

    /// The read-back of a paste ends.
    func verify(_ verification: PasteVerification) { verificationHandler?(verification) }

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
    var previews: [String] = []
    func showPreview(_ text: String) { previews.append(text) }

    init(log: CallLog) {
        self.log = log
    }

    func showRecording() {
        cardMessage = nil
        log.add("pill.recording")
    }
    func showHandsFree() { log.add("pill.handsFree") }
    func showHandsFreeNotice(_ text: String, duration: TimeInterval) {
        notices.append(text)
        log.add("pill.notice:\(text)")
    }
    func showProcessing() {
        cardMessage = nil
        log.add("pill.processing")
    }
    func showMessage(_ message: PillMessage, duration: TimeInterval) {
        cardMessage = nil
        messages.append(message)
        log.add("pill.message:\(message.headline)")
    }
    func hide() {
        cardMessage = nil
        log.add("pill.hide")
    }
    var cardMessage: PillMessage?
    func showCardMessage(_ message: PillMessage) {
        cardMessage = message
        log.add("pill.card:\(message.detail ?? message.headline)")
    }
    var cardHides = 0
    func hideCardMessage() {
        cardMessage = nil
        cardHides += 1
    }
    var cardHeld: Bool { cardMessage != nil }
}

@MainActor
private final class FakeCards: DictationCards {
    let log: CallLog
    var presented: [DeliveryCard] = []
    var onUndo: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?
    var onCardChange: (@MainActor (DeliveryCard?) -> Void)?

    init(log: CallLog) {
        self.log = log
    }

    var actions: [CardAction: @MainActor () -> Void] = [:]

    func present(_ card: DeliveryCard, actions: [CardAction: @MainActor () -> Void]) {
        presented.append(card)
        self.actions = actions
        log.add("card.present:\(card.kind)")
        onCardChange?(card)
    }

    /// Clicks a button on the card up now.
    func click(_ action: CardAction) {
        let handler = actions[action]
        actions = [:]
        handler?()
    }

    func dismiss() {
        log.add("card.dismiss")
        onCardChange?(nil)
    }
}

@MainActor
private final class FakeSounds: SoundPlayer {
    let log: CallLog
    var startCueDuration: TimeInterval = 0
    var isStartCuePlaying = false

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
private final class FakeAudioQuiet: RecordingAudioQuieting {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func begin() { log.add("audio.quiet") }
    func end() { log.add("audio.restore") }
}

private final class CaptureLanguageChoice: @unchecked Sendable {
    // Every read and write uses the lock, including the pipeline's Sendable callback.
    private let lock = NSLock()
    private var value = DictationLanguageRequest.explicit(.german)
    func get() -> DictationLanguageRequest { lock.withLock { value } }
    func change() { lock.withLock { value = .explicit(.japanese) } }
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
    let audioQuiet: FakeAudioQuiet
    let cards: FakeCards
    let controller: DictationController
    let clock: FakeClock
    var finishedAttempts: Counter
    let handsFreeChanges = Counter()
    let soundSettingsOpened = Counter()

    final class Counter {
        var count = 0
    }

    init(
        audio: CapturedAudio = capturedTone(), withStore: Bool = true, settings: CleanupSettings = CleanupSettings(),
        vocabulary: FakeVocabulary = FakeVocabulary(), textPipeline: TextPipeline = TextPipeline(),
        limits: DictationController.Limits = .standard, partials: Bool = false, archive: (any DictationArchiving)? = nil,
        quietAudio: Bool = false, appStyles: @escaping @Sendable () -> AppCleanupStyles = { AppCleanupStyles() }, previewEnabled: Bool = false,
        audioRetention: AudioRetentionPolicy = AudioRetentionPolicy(), storeWriter: (any DictationStoring)? = nil,
        smart: (any SmartCleaning)? = nil, languageRequest: @escaping @Sendable () -> DictationLanguageRequest = { .english }
    ) {
        capture = FakeCapture(log: log, audio: audio)
        engine = FakeEngine(log: log)
        store = FakeStore(log: log)
        inserter = FakeInserter(log: log)
        pill = FakePill(log: log)
        sounds = FakeSounds(log: log)
        audioQuiet = FakeAudioQuiet(log: log)
        cards = FakeCards(log: log)
        let clock = FakeClock(start: keyUp)
        self.clock = clock
        var pipeline = DictationPipeline(
            store: storeWriter ?? (withStore ? store : nil), archive: archive ?? FakeArchive(log: log, writesPartials: partials), engine: engine, clock: clock
        )
        pipeline.settings = { settings }
        pipeline.languageRequest = languageRequest
        pipeline.appStyles = appStyles
        pipeline.smart = smart
        pipeline.vocabulary = vocabulary
        pipeline.textPipeline = textPipeline
        pipeline.audioRetention = { audioRetention }
        let opened = soundSettingsOpened
        controller = DictationController(
            capture: capture, engine: engine, pipeline: pipeline, inserter: inserter, pill: pill, sounds: sounds, clock: clock,
            cards: cards, limits: limits, audioQuiet: quietAudio ? audioQuiet : nil,
            preview: LivePreviewSession(pause: { try await clock.sleep(forSeconds: 2) }), previewEnabled: { previewEnabled },
            openSoundSettings: { opened.count += 1 }
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

    /// Waits, up to two seconds, for work on other tasks to reach `condition`.
    func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            await settle()
        }
    }

    func dictate() async {
        await controller.handle(.pressed(at: keyDown))
        await controller.handle(.released(at: keyUp))
        await controller.waitForProcessing()
    }
}

@MainActor
@Suite struct DictationCleanupTests {
    @Test func detailedAccessibilityReadsStartAfterMicrophoneCapture() async throws {
        let rig = Rig()
        await rig.dictate()
        let app = try #require(rig.log.index(of: "inserter.application"))
        let capture = try #require(rig.log.index(of: "capture.start"))
        let ax = try #require(rig.log.index(of: "inserter.snapshot"))
        #expect(app < capture && capture < ax)
        #expect(rig.inserter.startFocusSeen?.role == "AXTextArea")
    }

    @Test func movingAppsDuringCaptureStartCannotAttributeTheNewFieldsToTheSource() async {
        let rig = Rig()
        rig.capture.duringStart = {
            rig.inserter.focus = FocusSnapshot(pid: 9, bundleID: "org.example.other", appName: "Other", role: "AXButton")
        }
        await rig.dictate()
        #expect(rig.inserter.startFocusSeen?.bundleID == "com.apple.Notes")
        #expect(rig.inserter.startFocusSeen?.role == nil)
        #expect(rig.store.start?.target.bundleID == "com.apple.Notes")
    }

    private let messy = "um so the build is uh green new line ship it"
    private let cleaned = "So the build is green\nShip it"

    @Test func recordingKeepsTheLanguageChosenAtKeyDown() async {
        let choice = CaptureLanguageChoice()
        let rig = Rig(languageRequest: { choice.get() })
        rig.engine.result.text = "Das ist ein deutscher Satz."
        await rig.controller.handle(.pressed(at: keyDown))
        choice.change()
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        #expect(rig.engine.languages == [.explicit(.german)])
        #expect(rig.inserter.delivered == ["Das ist ein deutscher Satz."])
    }

    @Test func pressKeepsItsLanguageWhileWaitingForAnEarlierStop() async {
        let choice = CaptureLanguageChoice()
        let rig = Rig(languageRequest: { choice.get() })
        await rig.lockIn()
        let gate = StartGate()
        defer { gate.open() }
        rig.capture.duringStop = { await gate.wait() }
        rig.controller.stopHandsFree()
        let next = Task { await rig.controller.handle(.pressed(at: keyDown + 4_000_000_000)) }
        await rig.until { rig.controller.isStartReserved }
        #expect(rig.controller.isStartReserved)
        choice.change()
        rig.capture.duringStop = nil
        gate.open()
        await next.value
        await rig.controller.handle(.released(at: keyUp + 4_000_000_000))
        await rig.controller.waitForProcessing()
        #expect(rig.engine.languages == [.explicit(.german), .explicit(.german)])
    }

    @Test func appToneUsesRecordingStartAppAndSurvivesPreferenceChanges() async throws {
        final class Styles: @unchecked Sendable {
            let lock = NSLock()
            private var value = AppCleanupStyles()
            func get() -> AppCleanupStyles { lock.withLock { value } }
            func set(_ style: StyleOptions) throws {
                try lock.withLock { try value.set(bundleID: "com.apple.Notes", appName: "Notes", style: style) }
            }
        }
        let styles = Styles()
        try styles.set(StylePreset.casual.options)
        let rig = Rig(appStyles: { styles.get() })
        rig.engine.result.text = "See Maya Friday."
        await rig.controller.handle(.pressed(at: keyDown))
        rig.inserter.focus = FocusSnapshot(pid: 9, bundleID: "org.example.other", appName: "Other")
        try styles.set(.formal)
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["See Maya Friday"])
        #expect(rig.store.insertion?.cleanup?.style == "casual")
        #expect(rig.inserter.startFocusSeen?.bundleID == "com.apple.Notes")
    }

    @Test func websiteRuleIsCapturedAfterCaptureStartsAndMissingRulesDoNotReadURL() async throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "slack.com", style: StylePreset.casual.options)
        let configured = styles
        let rig = Rig(appStyles: { configured })
        rig.inserter.focus.bundleID = "com.google.Chrome"
        rig.inserter.website = "work.slack.com"
        rig.engine.result.text = "See Maya Friday."
        await rig.controller.handle(.pressed(at: keyDown))
        let capture = try #require(rig.log.index(of: "capture.start"))
        let website = try #require(rig.log.index(of: "inserter.website"))
        #expect(capture < website)
        rig.inserter.website = "other.example"
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["See Maya Friday"])
        let plain = Rig()
        await plain.dictate()
        #expect(!plain.log.contains("inserter.website"))
    }

    @Test func aSlowPageURLReadFallsBackToTheAppRuleAndNeverLeaksIntoTheNextTake() async throws {
        var styles = AppCleanupStyles()
        try styles.setWebsite(domain: "slack.com", style: StylePreset.casual.options)
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: StylePreset.veryCasual.options)
        let configured = styles
        let rig = Rig(appStyles: { configured })
        rig.controller.websiteBudget = 0.05
        rig.inserter.focus.bundleID = "com.google.Chrome"
        rig.inserter.website = "work.slack.com"
        let gate = DispatchSemaphore(value: 0)
        rig.inserter.websiteGate = gate
        rig.engine.result.text = "See Maya Friday."
        await rig.dictate()
        // The hung read is abandoned at its budget and the app rule answers.
        #expect(rig.store.insertion?.cleanup?.style == "veryCasual")
        gate.signal()

        // A later take with a fast read gets its own site, not the abandoned read's.
        rig.inserter.websiteGate = nil
        rig.controller.websiteBudget = 5
        rig.inserter.website = "work.slack.com"
        await rig.dictate()
        #expect(rig.store.insertion?.cleanup?.style == "casual")
    }

    @Test func contextWebsitesApplyWithoutAnyLegacyWebsiteRule() async throws {
        let builtIn = AppCleanupStyles()
        let rig = Rig(appStyles: { builtIn })
        rig.inserter.focus.bundleID = "com.google.Chrome"
        rig.inserter.website = "www.linkedin.com"
        rig.engine.result.text = "See Maya Friday."
        await rig.dictate()
        #expect(rig.log.contains("inserter.website"))
        #expect(rig.store.insertion?.cleanup?.style == "casual")

        var added = AppCleanupStyles()
        added.contexts.addSite(.personal, domain: "example.org")
        added.contexts.setTone(.personal, .veryCasual)
        let configured = added
        let custom = Rig(appStyles: { configured })
        custom.inserter.focus.bundleID = "com.google.Chrome"
        custom.inserter.website = "example.org"
        custom.engine.result.text = "See Maya Friday."
        await custom.dictate()
        #expect(custom.store.insertion?.cleanup?.style == "veryCasual")
    }

    @Test func unknownAppUsesGlobalToneAndOffStillBypassesTone() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: StylePreset.veryCasual.options)
        let configured = styles
        let unknown = Rig(appStyles: { configured })
        unknown.inserter.focus = FocusSnapshot()
        unknown.engine.result.text = "See Maya Friday."
        await unknown.dictate()
        #expect(unknown.inserter.delivered == ["See Maya Friday."])
        #expect(unknown.store.insertion?.cleanup?.style == "formal")
        var settings = CleanupSettings()
        settings.level = .off
        let off = Rig(settings: settings, appStyles: { configured })
        off.engine.result.text = "See Maya Friday."
        await off.dictate()
        #expect(off.inserter.delivered == ["See Maya Friday."])
        #expect(off.store.insertion?.cleanup?.outcome == "skipped")
    }

    @Test func appRuleLevelOffSkipsCleanupForThatTakeOnly() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: nil, level: .off)
        let configured = styles
        let rig = Rig(appStyles: { configured })
        rig.engine.result.text = messy
        await rig.dictate()
        #expect(rig.inserter.delivered == [messy])
        #expect(rig.store.insertion?.cleanup?.level == "off" && rig.store.insertion?.cleanup?.outcome == "skipped")
        let plain = Rig()
        plain.engine.result.text = messy
        await plain.dictate()
        #expect(plain.inserter.delivered == [cleaned])
    }

    @Test func appRuleLevelTurnsCleanupOnWhenTheGlobalLevelIsOff() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: nil, level: .basic)
        let configured = styles
        var settings = CleanupSettings()
        settings.level = .off
        let rig = Rig(settings: settings, appStyles: { configured })
        rig.engine.result.text = messy
        await rig.dictate()
        #expect(rig.inserter.delivered == [cleaned])
        #expect(rig.store.insertion?.cleanup?.level == "basic")
    }

    @Test func recordingStartPrewarmsFromTheRulesLevelNotTheGlobalOne() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: nil, level: .medium)
        let configured = styles
        var settings = CleanupSettings()
        settings.level = .off
        let spy = SpySmart()
        let rig = Rig(settings: settings, appStyles: { configured }, smart: spy)
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(spy.levels == [.medium])
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()

        let plain = SpySmart()
        let other = Rig(settings: settings, appStyles: { configured }, smart: plain)
        other.inserter.focus = FocusSnapshot(pid: 9, bundleID: "org.example.other", appName: "Other")
        await other.controller.handle(.pressed(at: keyDown))
        #expect(plain.levels == [.off])
    }

    @Test func recordingStartPrewarmsAgainWhenTheWebsiteRuleNeedsAModel() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: nil, level: .basic)
        try styles.setWebsite(domain: "slack.com", style: nil, level: .medium)
        let configured = styles
        let spy = SpySmart()
        let rig = Rig(appStyles: { configured }, smart: spy)
        rig.inserter.focus.bundleID = "com.google.Chrome"
        rig.inserter.website = "work.slack.com"
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(spy.levels == [.basic, .medium])
        #expect(Set(spy.takes).count == 1)
    }

    @Test func theTakesPrewarmHoldEndsWithTheTakeOnEveryExit() async throws {
        let cancelSpy = SpySmart()
        let cancelRig = Rig(smart: cancelSpy)
        await cancelRig.controller.handle(.pressed(at: keyDown))
        #expect(cancelSpy.released.isEmpty)
        await cancelRig.controller.handle(.cancelled(reason: .escape))
        #expect(cancelSpy.released == cancelSpy.takes)
        #expect(cancelSpy.released.count == 1)

        let deliverSpy = SpySmart()
        let deliverRig = Rig(smart: deliverSpy)
        await deliverRig.controller.handle(.pressed(at: keyDown))
        await deliverRig.controller.handle(.released(at: keyUp))
        await deliverRig.controller.waitForProcessing()
        #expect(deliverSpy.released.contains(deliverSpy.takes[0]))
    }

    @Test func websiteRuleLevelBeatsTheAppRuleLevel() async throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.google.Chrome", appName: "Chrome", style: nil, level: .basic)
        try styles.setWebsite(domain: "slack.com", style: nil, level: .off)
        let configured = styles
        let rig = Rig(appStyles: { configured })
        rig.inserter.focus.bundleID = "com.google.Chrome"
        rig.inserter.website = "work.slack.com"
        rig.engine.result.text = messy
        await rig.dictate()
        #expect(rig.inserter.delivered == [messy])
        #expect(rig.store.insertion?.cleanup?.outcome == "skipped")
        let app = Rig(appStyles: { configured })
        app.inserter.focus.bundleID = "com.google.Chrome"
        app.inserter.website = "example.org"
        app.engine.result.text = messy
        await app.dictate()
        #expect(app.inserter.delivered == [cleaned])
        #expect(app.store.insertion?.cleanup?.level == "basic")
    }

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
        off.level = .off
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

    @Test func slowCleanupStillDropsTheGuardedTag() async throws {
        let rig = Rig(textPipeline: TextPipeline(numberFormatter: SlowNumbers()))
        rig.engine.result.text = "[MUSIC] ship it"
        await rig.dictate()
        #expect(rig.inserter.delivered == ["ship it"])
        #expect(rig.store.insertion?.cleanup?.outcome == "timeout")
        #expect(rig.store.transcription?.rawText == "[MUSIC] ship it")
        #expect(rig.store.insertion?.detText == "ship it")
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

    @Test func thePillStaysUnderADeliveryCardAndShowsItsDetail() async {
        let rig = Rig()
        rig.engine.result.text = messy
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        await rig.dictate()
        #expect(rig.pill.cardMessage == PillMessage(DeliveryCard.textIsSafe, isError: true))
        #expect(!rig.log.contains("pill.hide"))
    }

    @Test func dismissingTheCardTakesTheCardMessageDown() async {
        let rig = Rig()
        rig.engine.result.text = messy
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        await rig.dictate()
        rig.cards.dismiss()
        #expect(rig.pill.cardMessage == nil)
        #expect(rig.pill.cardHides == 2)
    }

    @Test func aReplacementCardUpdatesTheCardMessage() async {
        let rig = Rig()
        rig.cards.present(.secure("hello"))
        #expect(rig.pill.cardMessage?.headline == DeliveryCard.textIsSafe)
        rig.cards.present(.notLanded("hello"))
        #expect(rig.pill.cardMessage == PillMessage("The field didn't change", isError: true))
        rig.cards.present(.cancelled())
        #expect(rig.pill.cardMessage == nil)
    }

    private func lastPill(_ rig: Rig) -> String? { rig.log.all.last(where: { $0.hasPrefix("pill.") }) }

    @Test func aJobEndingWithNoCardPutsAnEarlierCardsLineBack() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = [""]
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        rig.cards.present(.secure("earlier"))
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.pill.cardMessage?.headline == DeliveryCard.textIsSafe)
        #expect(!rig.log.contains("pill.hide"))
    }

    @Test func aQueuedJobShowsProcessingOverAnEarlierCardsLine() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["First one.", "Second one."]
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        rig.cards.present(.secure("earlier"))
        #expect(rig.pill.cardMessage != nil)
        await rig.controller.handle(.pressed(at: keyUp + 1))
        await rig.controller.handle(.released(at: keyUp + 2))
        #expect(lastPill(rig) == "pill.processing")
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
    }

    @Test func dismissingTheCardMidJobLeavesProcessingOnThePill() async {
        let rig = Rig()
        rig.engine.holds = 1
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        rig.cards.present(.secure("earlier"))
        rig.cards.dismiss()
        #expect(lastPill(rig) == "pill.processing")
        #expect(!rig.log.contains("pill.hide"))
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
    }

    @Test func aCardFromAnEarlierJobMidRecordingDoesNotStickTheRecordingPill() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["First one.", "Second one."]
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: false, target: nil, finalText: "")
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        #expect(rig.controller.phase == .recording)
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        // The card arrived mid-recording, so its line stayed off the recording pill.
        #expect(rig.cards.presented.count == 1 && lastPill(rig) == "pill.recording")
        await rig.controller.handle(.released(at: keyUp + 2))
        await rig.controller.waitForProcessing()
        #expect(rig.controller.phase == .idle)
        #expect(rig.cards.presented == [.secure("First one."), .secure("Second one.")])
        #expect(rig.pill.cardMessage == PillMessage(DeliveryCard.textIsSafe, isError: true))
        #expect(lastPill(rig) == "pill.card:\(DeliveryCard.textIsSafe)")
    }

    @Test func aCardWithNoDetailLeavesThePillHidden() async {
        let rig = Rig()
        rig.cards.present(.cancelled())
        #expect(rig.pill.cardMessage == nil)
        #expect(rig.pill.cardHides == 1)
        #expect(!rig.log.all.contains { $0.hasPrefix("pill.card:") })
    }

    @Test func aCardRaisedDuringARecordingDoesNotTakeTheRecordingPill() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.cards.present(.limitWarning(stopsAfter: 1200))
        #expect(rig.pill.cardMessage == nil)
        #expect(!rig.log.all.contains { $0.hasPrefix("pill.card:") })
    }
}

@MainActor
private final class FakeCorrections: CorrectionObserving {
    var pastes: [(text: String, id: String, pid: pid_t?)] = []
    var starts = 0
    var notLanded: [String] = []
    func pasteDidNotLand(dictationID: String) { notLanded.append(dictationID) }
    func pasted(_ text: String, dictationID: String, target: FocusSnapshot?) { pastes.append((text, dictationID, target?.pid)) }
    func dictationStarted() { starts += 1 }
}

@MainActor
@Suite struct DictationControllerTests {
    @Test @MainActor func provisionalWordsNeverInsertAndFinalDeliversOnce() async {
        let rig = Rig(previewEnabled: true)
        rig.capture.available = 48_000
        await rig.controller.handle(.pressed(at: keyDown))
        for _ in 0..<200 where rig.clock.sleeperCount < 2 { await Task.yield() }
        rig.clock.advance(by: 2)
        for _ in 0..<200 where rig.engine.previewCalls == 0 { await Task.yield() }
        await rig.settle()
        #expect(rig.pill.previews.contains("Provisional words that must not be inserted."))
        #expect(rig.inserter.delivered.isEmpty)
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.pill.previews.last == "")
    }

    @Test @MainActor func canceledPreviewNeverDeliversAndDefaultOffDoesNoInference() async {
        for enabled in [false, true] {
            let rig = Rig(previewEnabled: enabled)
            rig.capture.available = 48_000
            await rig.controller.handle(.pressed(at: keyDown))
            for _ in 0..<100 { await Task.yield() }
            rig.clock.advance(by: 2)
            for _ in 0..<100 { await Task.yield() }
            #expect(rig.engine.previewCalls == (enabled ? 1 : 0))
            await rig.controller.handle(.cancelled(reason: .escape))
            await rig.settle()
            #expect(rig.inserter.delivered.isEmpty)
            #expect(rig.pill.previews.last == "")
        }
    }

    @Test func recordingWaitsWhileSavedAudioIsBeingRecovered() async {
        let rig = Rig()
        rig.controller.canStartRecording = { false }
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(!rig.log.contains("capture.start"))
        #expect(rig.controller.phase == .idle)
    }

    @Test func repeatedReleaseOnlyPlaysOneStopAndDeliversOnce() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.handle(.released(at: keyUp + 1))
        await rig.controller.waitForProcessing()
        await rig.controller.handle(.released(at: keyUp + 2))
        #expect(rig.log.all.filter { $0 == "sound.stop" }.count == 1)
        #expect(rig.inserter.delivered.count == 1)
    }

    @Test func aPastedDictationIsHandedToTheCorrectionWatcherAndANewOneStopsIt() async {
        let rig = Rig()
        let corrections = FakeCorrections()
        rig.controller.corrections = corrections
        rig.inserter.result = DeliveryResult(
            method: .paste, outcome: .unknown, focusMoved: false, target: FocusSnapshot(pid: 42), finalText: " Hello world."
        )
        await rig.dictate()
        #expect(corrections.starts == 1)
        #expect(corrections.pastes.count == 1 && corrections.pastes.first?.text == " Hello world." && corrections.pastes.first?.pid == 42)
        #expect(corrections.pastes.first?.id.isEmpty == false)
    }

    @Test func nothingIsWatchedWhenTheTextDidNotLandInAField() async {
        let rig = Rig()
        let corrections = FakeCorrections()
        rig.controller.corrections = corrections
        rig.inserter.result = DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: false, target: nil, finalText: "x")
        await rig.dictate()
        rig.inserter.result = DeliveryResult(method: .paste, outcome: .failed("no"), focusMoved: false, target: nil, finalText: "x")
        await rig.dictate()
        #expect(corrections.pastes.isEmpty && corrections.starts == 2)
    }

    @Test func happyPathRunsTheCollaboratorsInOrder() async throws {
        let rig = Rig()
        await rig.dictate()

        #expect(
            rig.log.all == [
                "card.dismiss", "inserter.application", "capture.start", "inserter.snapshot", "sound.start", "pill.recording", "store.begin",
                "pill.processing", "capture.stop", "sound.stop",
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

    @Test(arguments: [AudioRetentionAge.days14, .noAgeLimit])
    func selectedAudioRetentionChangesOnlyNewAudioExpiration(age: AudioRetentionAge) async throws {
        let policy = AudioRetentionPolicy(age: age)
        let rig = Rig(audioRetention: policy)
        await rig.dictate()
        let capture = try #require(rig.store.capture)
        #expect(capture.audioExpiresAt == policy.expiration(from: FakeClock.wall))
        #expect(capture.audioPath != nil)
        #expect(rig.store.transcription?.rawText == "Hello world.")
        #expect(rig.inserter.delivered == ["Hello world."])
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

    @Test func updaterGatePreservesUndoAudioUntilWorkCanResume() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        let gate = Rig.Counter()
        rig.controller.canStartRecording = { gate.count == 1 }
        await rig.controller.undoCancel()
        #expect(!rig.log.contains("engine.transcribe") && rig.inserter.delivered.isEmpty)
        gate.count = 1
        await rig.controller.undoCancel()
        #expect(rig.inserter.delivered == ["Hello world."])
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
        #expect(
            tail == [
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

    @Test func undoWorksWhileAnEarlierDictationIsStillProcessing() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["First one.", "Second one."]
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        await rig.controller.handle(.cancelled(reason: .escape))
        #expect(rig.controller.phase == .processing)

        let undo = Task { await rig.controller.undoCancel() }
        await rig.until { rig.store.reopens == 1 }
        // Queued behind the first take: reopened and archived already, but nothing delivered yet.
        #expect(rig.inserter.delivered.isEmpty && rig.store.reopens == 1)

        rig.engine.releaseHeld()
        await undo.value
        await rig.controller.waitForProcessing()
        #expect(rig.store.reopens == 1)
        #expect(rig.inserter.delivered == ["First one.", "Second one."])
    }

    @Test func quitBehindALongTakeFindsAnUndoneTakeAlreadySaved() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["First one.", "Second one."]
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        await rig.controller.handle(.cancelled(reason: .escape))
        let undo = Task { await rig.controller.undoCancel() }
        await rig.until { rig.store.reopens == 1 }

        // The first take is still held. Quit must not wait on it to see the second take's audio saved.
        #expect(await rig.controller.prepareForTermination())
        #expect(rig.store.reopens == 1)

        rig.engine.releaseHeld()
        await undo.value
        await rig.controller.waitForProcessing()
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

    @Test(arguments: [CaptureError.microphoneDenied, .microphonePending])
    func unpreparedCaptureReportsItsActualPermissionFailure(error: CaptureError) async {
        let rig = Rig()
        rig.capture.isPrepared = false
        rig.capture.startError = error
        await rig.controller.handle(.pressed(at: keyDown))

        #expect(rig.log.contains("capture.start") && rig.log.contains("capture.cancel"))
        #expect(rig.pill.messages == [PillMessage("Microphone access needed", detail: "Allow it in System Settings", isError: true)])
        #expect(!rig.log.contains("pill.recording") && !rig.log.contains("engine.transcribe"))
        #expect(rig.inserter.delivered.isEmpty && rig.cards.presented.isEmpty)
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.controller.phase == .idle && rig.finishedAttempts.count == 1)
    }

    @Test(arguments: [CaptureError.noInputDevice, .invalidInputFormat(sampleRate: 0, channels: 0)])
    func unpreparedCaptureRetriesTheDeviceOnEachExplicitPress(error: CaptureError) async {
        let rig = Rig()
        rig.capture.isPrepared = false
        rig.capture.startError = error
        await rig.controller.handle(.pressed(at: keyDown))

        #expect(rig.pill.messages == [PillMessage("No microphone found", detail: "Connect one and try again", isError: true)])
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
        #expect(rig.controller.phase == .idle)

        rig.capture.startError = nil
        await rig.settle()
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        #expect(rig.inserter.delivered.isEmpty)
        await rig.dictate()

        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 2)
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.controller.phase == .idle)
    }

    @Test(arguments: [true, false])
    func unpreparedCapturePreservesQueuedReleaseOrCancel(cancel: Bool) async {
        let rig = Rig()
        rig.capture.isPrepared = false
        let starts = Rig.Counter()
        rig.capture.duringStart = {
            starts.count += 1
            await rig.settle()
            #expect(!rig.log.contains("capture.stop") && !rig.log.contains("capture.cancel"))
        }
        let (events, sink) = AsyncStream.makeStream(of: HotkeyEvent.self)
        sink.yield(.pressed(at: keyDown))
        sink.yield(cancel ? .cancelled(reason: .escape) : .released(at: keyUp))
        sink.finish()
        await rig.controller.consume(events)
        await rig.controller.waitForProcessing()
        await rig.settle()

        #expect(starts.count == 1)
        #expect(rig.store.finishes.map(\.0) == (cancel ? [.cancelled] : []))
        #expect(rig.inserter.delivered == (cancel ? [] : ["Hello world."]))
        #expect(rig.log.contains("engine.transcribe") == !cancel)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        #expect(rig.controller.phase == .idle && rig.finishedAttempts.count == 1)
        rig.clock.advance(by: 10)
        await rig.settle()
        #expect(rig.clock.sleeperCount == 0)
        #expect(rig.inserter.delivered == (cancel ? [] : ["Hello world."]))
    }

    @Test func releaseRequestedBeforeInferenceWaitsForHeldEntry() async throws {
        let rig = Rig()
        rig.engine.holds = 1
        var released = false
        var releaseTask: Task<Void, Never>?
        await withCheckedContinuation { started in
            releaseTask = Task { @MainActor in
                started.resume()
                await rig.engine.waitForHeld()
                rig.engine.releaseHeld()
                released = true
            }
        }
        try #require(!released)

        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await releaseTask?.value
        await rig.controller.waitForProcessing()
        #expect(released)
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 1)
        #expect(rig.log.all.filter { $0 == "engine.transcribe" }.count == 1)
    }

    @Test func pressWhileProcessingStartsRecordingAndWaitsItsTurn() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["First one.", "Second one."]
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        #expect(rig.controller.phase == .processing)
        #expect(rig.log.contains("engine.transcribe") && rig.inserter.delivered.isEmpty)

        await rig.controller.handle(.pressed(at: keyUp + 1))
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 2)
        #expect(rig.controller.phase == .recording)
        #expect(rig.pill.messages.isEmpty)
        #expect(rig.log.all.last(where: { $0.hasPrefix("pill.") }) == "pill.recording")

        // The first finishes while the second is still being spoken: the pill and phase stay with the recording.
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["First one."])
        #expect(rig.controller.phase == .recording)
        #expect(rig.log.all.last(where: { $0.hasPrefix("pill.") }) == "pill.recording")

        await rig.controller.handle(.released(at: keyUp + 2))
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["First one.", "Second one."])
        #expect(rig.controller.phase == .idle)
        #expect(rig.finishedAttempts.count == 2)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 2)
    }

    @Test func aQueuedRecordingIsOnDiskBeforeTheEarlierOnesFinish() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.texts = ["One.", "Two.", "Three."]
        for index in 0..<3 {
            await rig.controller.handle(.pressed(at: keyDown + UInt64(index) * 10))
            await rig.controller.handle(.released(at: keyUp + UInt64(index) * 10))
            if index == 0 { await rig.engine.waitForHeld() }
        }
        // All three are captured and archived while the first still sits in the engine.
        await rig.until { rig.log.all.filter { $0 == "archive.write" }.count == 3 }
        #expect(rig.log.all.filter { $0 == "archive.write" }.count == 3)
        #expect(rig.log.all.filter { $0 == "engine.transcribe" }.count == 1)
        #expect(rig.inserter.delivered.isEmpty && rig.controller.phase == .processing)

        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["One.", "Two.", "Three."])
        #expect(rig.store.finishes.isEmpty)
        #expect(rig.controller.phase == .idle && rig.finishedAttempts.count == 3)
        let log = rig.log.all
        let delivers = log.indices.filter { log[$0] == "inserter.deliver" }
        let transcribes = log.indices.filter { log[$0] == "engine.transcribe" }
        #expect(delivers.count == 3 && transcribes.count == 3)
        #expect(delivers[0] < transcribes[1] && delivers[1] < transcribes[2])
    }

    @Test func aFailureInAQueuedDictationLeavesTheNewRecordingAlone() async {
        let rig = Rig()
        rig.engine.holds = 1
        rig.engine.error = Boom()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.controller.phase == .recording)
        #expect(!rig.log.contains("capture.cancel") && rig.pill.messages.isEmpty)
        #expect(rig.log.contains("sound.error"))
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

    // MARK: Read-back

    private func pastedResult(id: Int? = 1) -> DeliveryResult {
        DeliveryResult(
            method: .paste, outcome: .unknown, focusMoved: false, target: FocusSnapshot(pid: 42), finalText: " Hello world.",
            verificationID: id
        )
    }

    @Test func aNotLandedVerdictUpdatesTheRowRaisesTheCardAndStopsTheWatcher() async {
        let rig = Rig()
        let corrections = FakeCorrections()
        rig.controller.corrections = corrections
        rig.inserter.result = pastedResult()
        await rig.dictate()
        #expect(rig.cards.presented.isEmpty)
        rig.inserter.verify(PasteVerification(id: 1, verdict: .notLanded, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.map(\.outcome) == ["not landed"])
        #expect(rig.cards.presented == [.notLanded(" Hello world.")])
        #expect(rig.cards.presented.first?.header == "Paste didn't land\nThe field didn't change")
        #expect(rig.cards.presented.first?.actions == [.copy])
        #expect(corrections.notLanded == [corrections.pastes.first?.id])
    }

    @Test func aConfirmedVerdictWritesTheOutcomeAndTheReceiptAndStaysSilent() async {
        let rig = Rig()
        let corrections = FakeCorrections()
        rig.controller.corrections = corrections
        rig.inserter.result = pastedResult()
        await rig.dictate()
        rig.inserter.verify(PasteVerification(id: 1, verdict: .confirmed, receiptMs: 37))
        await rig.settle()
        #expect(rig.store.verdicts.count == 1 && rig.store.verdicts.first?.outcome == "confirmed" && rig.store.verdicts.first?.receiptMs == 37)
        #expect(rig.cards.presented.isEmpty && corrections.notLanded.isEmpty)
    }

    @Test func anUnknownVerdictStaysSilentAndKeepsTheOutcome() async {
        let rig = Rig()
        rig.inserter.result = pastedResult()
        await rig.dictate()
        rig.inserter.verify(PasteVerification(id: 1, verdict: .unknown, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.map(\.outcome) == ["unknown"])
        #expect(rig.cards.presented.isEmpty)
    }

    @Test func aStaleVerdictIsDropped() async {
        let rig = Rig()
        rig.inserter.result = pastedResult(id: 2)
        await rig.dictate()
        rig.inserter.verify(PasteVerification(id: 1, verdict: .notLanded, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.isEmpty && rig.cards.presented.isEmpty)
        rig.inserter.verify(PasteVerification(id: 2, verdict: .confirmed, receiptMs: nil))
        rig.inserter.verify(PasteVerification(id: 2, verdict: .notLanded, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.map(\.outcome) == ["confirmed"] && rig.cards.presented.isEmpty)
    }

    @Test func aNewDictationCancelsThePendingReadBack() async {
        let rig = Rig()
        rig.inserter.result = pastedResult()
        await rig.dictate()
        let before = rig.inserter.cancelledVerifications
        await rig.controller.handle(.pressed(at: 1))
        #expect(rig.inserter.cancelledVerifications == before + 1)
        rig.inserter.verify(PasteVerification(id: 1, verdict: .notLanded, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.isEmpty && rig.cards.presented.isEmpty)
    }

    @Test func aPasteWithNoReadBackWritesNoVerdict() async {
        let rig = Rig()
        rig.inserter.result = pastedResult(id: nil)
        await rig.dictate()
        rig.inserter.verify(PasteVerification(id: 1, verdict: .notLanded, receiptMs: nil))
        await rig.settle()
        #expect(rig.store.verdicts.isEmpty && rig.cards.presented.isEmpty)
    }

    @Test func silenceNeverReachesTheEngine() async {
        let rig = Rig(
            audio: CapturedAudio(
                samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, deviceUID: nil, deviceName: nil,
                deviceTransport: "built-in", firstSampleMs: 20, firstNonzeroMs: nil, captureStartMs: 10, audioMs: 1_000
            ))
        await rig.dictate()

        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(!rig.log.contains("engine.transcribe"))
        #expect(rig.log.contains("archive.write"))
        #expect(rig.inserter.delivered.isEmpty)
    }

    private func silentAudio(level: Float = 0, deviceName: String? = "Studio Mic") -> CapturedAudio {
        CapturedAudio(
            samples: [Float](repeating: level, count: 16_000), sampleRate: 16_000, deviceUID: nil, deviceName: deviceName,
            deviceTransport: "usb", firstSampleMs: 20, firstNonzeroMs: nil, captureStartMs: 10, audioMs: 1_000
        )
    }

    @Test func aSilentTakeHeldLongEnoughNamesTheMicAndOffersSoundSettings() async {
        let rig = Rig(audio: silentAudio())
        await rig.dictate()
        let card = rig.cards.presented.last
        #expect(rig.cards.presented.count == 1)
        #expect(card?.kind == .silentMic)
        #expect(card?.header == "Microphone heard nothing\nCheck Studio Mic")
        #expect(card?.actions == [.openSoundSettings])
        rig.cards.click(.openSoundSettings)
        #expect(rig.soundSettingsOpened.count == 1)
    }

    @Test func aTapTooShortToBeADictationRaisesNoCard() async {
        let rig = Rig(audio: silentAudio())
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyDown + 500_000_000))
        await rig.controller.waitForProcessing()
        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(rig.cards.presented.isEmpty)
    }

    @Test func repeatedSilentTakesRaiseOneCard() async {
        let rig = Rig(audio: silentAudio())
        await rig.dictate()
        await rig.dictate()
        #expect(rig.cards.presented.count == 1)
    }

    @Test func audibleNoiseWithoutSpeechSaysNoSpeechWasHeard() async {
        // Steady low hiss: above the no-signal floor, never voiced.
        let rig = Rig(audio: silentAudio(level: 0.002, deviceName: nil))
        await rig.dictate()
        #expect(rig.cards.presented.last?.header == "No speech heard\nCheck your microphone")
    }

    @Test func anEmptyResultFromRealSpeechRaisesNoSilentMicCard() async {
        let rig = Rig()
        rig.engine.result.text = "[BLANK_AUDIO]"
        await rig.dictate()
        #expect(rig.store.finishes.map(\.0) == [.empty])
        #expect(rig.cards.presented.isEmpty)
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
            #expect(rig.pill.messages.isEmpty)
            guard let card = rig.cards.presented.first else {
                #expect(rig.log.contains("pill.hide"))
                continue
            }
            // The pill stays under the card with its detail line instead of hiding.
            #expect(rig.pill.cardMessage == card.pillMessage && !rig.log.contains("pill.hide"))
            #expect(card.header == header && card.actions == [.copy] && card.countdown == nil)
            #expect(card.transcript == (finalText.isEmpty ? "Hello world." : finalText))
        }
    }

    // MARK: Hands-free

    @Test func lockRecordsModeAndTriggerCuesAndTellsThePill() async throws {
        let rig = Rig()
        await rig.lockIn(.doubleTap)

        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)
        #expect(
            rig.log.all == [
                "card.dismiss", "inserter.application", "capture.start", "inserter.snapshot", "sound.start", "pill.recording", "store.begin",
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

    // MARK: Automation

    @Test func automationStartLocksHandsFree() async {
        let rig = Rig()
        await rig.controller.startHandsFree()
        #expect(rig.controller.phase == .recording && rig.controller.isHandsFree)
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
    }

    @Test func twoAutomationStartsBeginOneSession() async {
        let rig = Rig()
        // A recording just stopped, so the next press waits on the capture's stop. That wait is the window two URLs race in.
        await rig.lockIn()
        rig.capture.duringStop = { await rig.settle() }
        rig.controller.stopHandsFree()
        let before = rig.log.all.filter { $0 == "capture.start" }.count
        async let first: Void = rig.controller.startHandsFree()
        async let second: Void = rig.controller.startHandsFree()
        _ = await (first, second)
        await rig.settle()
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == before + 1)
        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)
    }

    @Test func aNoticeNeverTakesALiveRecordingsPill() async {
        let hands = Rig()
        await hands.lockIn()
        hands.controller.showNotice(PillMessage("Copied"))
        #expect(hands.pill.messages.isEmpty && hands.pill.notices == ["Copied"])
        #expect(!hands.log.contains("pill.hide") && hands.controller.phase == .recording)

        let held = Rig()
        await held.controller.handle(.pressed(at: keyDown))
        held.controller.showNotice(PillMessage("Automation is off"))
        #expect(held.pill.messages.isEmpty && held.pill.notices.isEmpty)

        let idle = Rig()
        idle.controller.showNotice(PillMessage("Copied"))
        #expect(idle.pill.messages.map(\.headline) == ["Copied"])
    }

    @Test(arguments: [true, false])
    func aNoticeAfterTheCaptureIsLiveKeepsTheRecordingPillWhileHistoryStarts(handsFree: Bool) async {
        let rig = Rig()
        let gate = StartGate()
        let reached = StartGate()
        rig.store.duringBegin = {
            reached.open()
            await gate.wait()
        }
        let start = Task { @MainActor in
            if handsFree { await rig.controller.startHandsFree() } else { await rig.controller.handle(.pressed(at: keyDown)) }
        }
        await reached.wait()
        // Capture is running and the recording pill is up; only the history row is still pending.
        #expect(rig.log.contains("pill.recording"))
        rig.controller.showNotice(PillMessage("Automation is off"))
        #expect(rig.pill.messages.isEmpty && rig.pill.notices.isEmpty)
        #expect(!rig.log.contains("pill.hide"))
        gate.open()
        await start.value
        await rig.settle()
        #expect(rig.controller.phase == .recording && rig.controller.isHandsFree == handsFree)
        #expect(rig.pill.messages.isEmpty)
    }

    @Test func aStopQueuedBehindAStartingRecordingStopsIt() async {
        let rig = Rig()
        let gate = StartGate()
        // Real clock off: a starved runner must not fire the 10 s wait limit and drop the queued command.
        rig.controller.automationWaitLimit = { try await Task.sleep(for: .seconds(3600)) }
        rig.capture.duringStart = { await gate.wait() }
        rig.controller.enqueueAutomation(.start)
        rig.controller.enqueueAutomation(.stop)
        await rig.settle()
        // The capture is still coming up, so the stop has not run and has not been dropped.
        #expect(rig.controller.phase == .recording && !rig.controller.isHandsFree)
        gate.open()
        await rig.controller.automationTail?.value
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.log.contains("capture.stop"))
    }

    @Test func aCancelQueuedBehindAStartingRecordingCancelsIt() async {
        let rig = Rig()
        let gate = StartGate()
        // Real clock off: a starved runner must not fire the 10 s wait limit and drop the queued command.
        rig.controller.automationWaitLimit = { try await Task.sleep(for: .seconds(3600)) }
        rig.capture.duringStart = { await gate.wait() }
        rig.controller.enqueueAutomation(.start)
        rig.controller.enqueueAutomation(.cancel)
        await rig.settle()
        gate.open()
        await rig.controller.automationTail?.value
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.inserter.delivered.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aStartDroppedForAnInFlightStartShowsANotice() async {
        let rig = Rig()
        let gate = StartGate()
        rig.capture.duringStart = { await gate.wait() }
        rig.controller.enqueueAutomation(.start)
        await rig.settle()
        #expect(rig.controller.isStartReserved)
        await rig.controller.startHandsFree()
        #expect(rig.pill.messages.map(\.headline) == ["Already starting"])
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        gate.open()
        await rig.controller.automationTail?.value

        // A start that finds a finished recording is still silent.
        await rig.controller.startHandsFree()
        #expect(rig.pill.messages.map(\.headline) == ["Already starting"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [DictationAutomationStep.stop, .cancel])
    func aStopQueuedBehindAHungStartEndsTheCaptureOnceTheStartComesUp(step: DictationAutomationStep) async {
        let rig = Rig()
        let hung = StartGate()
        let limit = StartGate()
        rig.capture.duringStart = { await hung.wait() }
        rig.controller.automationWaitLimit = { await limit.wait() }
        rig.controller.enqueueAutomation(.start)
        let startTask = rig.controller.automationTail
        rig.controller.enqueueAutomation(step)
        let endTask = rig.controller.automationTail
        await rig.settle()
        // Still waiting: the limit has not fired and the start has not returned.
        var endRan = false
        let watcher = Task { @MainActor in
            await endTask?.value; endRan = true
        }
        await rig.settle()
        #expect(!endRan)
        limit.open()
        await watcher.value
        #expect(endRan)
        // The start is still hung; letting it go must end the capture rather than lock it on.
        #expect(rig.controller.isStartReserved)
        hung.open()
        await startTask?.value
        await rig.controller.waitForProcessing()
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.controller.pendingAutomationEnd == nil && !rig.controller.automationStartPending)
        if step == .stop {
            #expect(rig.inserter.delivered == ["Hello world."])
            #expect(rig.log.contains("capture.stop"))
        } else {
            #expect(rig.store.finishes.map(\.0) == [.cancelled])
            #expect(rig.inserter.delivered.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func aCancelOnAHungStartWinsWhicheverOrderTheEndsArrive(cancelFirst: Bool) async {
        let rig = Rig()
        let gate = StartGate()
        rig.capture.duringStart = { await gate.wait() }
        let start = Task { @MainActor in await rig.controller.startHandsFree() }
        await rig.settle()
        if cancelFirst {
            await rig.controller.cancelHandsFree()
            rig.controller.stopHandsFree()
        } else {
            rig.controller.stopHandsFree()
            await rig.controller.cancelHandsFree()
        }
        #expect(rig.controller.pendingAutomationEnd == .cancel)
        gate.open()
        await start.value
        await rig.controller.waitForProcessing()
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.controller.pendingAutomationEnd == nil && !rig.controller.automationStartPending)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowEarlierStartCannotClearALaterStartsPendingStop() async {
        let rig = Rig()
        let lockGate = StartGate()
        let limit = StartGate()
        let startB = StartGate()
        var locks = 0
        rig.store.duringLock = {
            locks += 1; if locks == 1 { await lockGate.wait() }
        }
        rig.controller.automationWaitLimit = { await limit.wait() }
        // A comes up hands-free, then suspends writing its lock.
        rig.controller.enqueueAutomation(.start)
        while locks == 0 { await Task.yield() }
        #expect(rig.controller.isHandsFree && !rig.controller.automationStartPending)
        // Stop A and start B go through once the wait limit fires, and B hangs coming up.
        rig.capture.duringStart = { await startB.wait() }
        rig.controller.enqueueAutomation(.stop)
        rig.controller.enqueueAutomation(.start)
        limit.open()
        await rig.settle()
        #expect(rig.controller.automationStartPending)
        // A's lock write finishes while B is pending, which used to wipe B's flags.
        lockGate.open()
        await rig.settle()
        #expect(rig.controller.automationStartPending)
        rig.controller.enqueueAutomation(.stop)
        let stopB = rig.controller.automationTail
        await rig.settle()
        #expect(rig.controller.pendingAutomationEnd == .stop)
        startB.open()
        await stopB?.value
        await rig.controller.waitForProcessing()
        while rig.controller.phase != .idle { await Task.yield() }
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
        #expect(rig.controller.pendingAutomationEnd == nil && !rig.controller.automationStartPending)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 2)
    }

    @Test func aFailedAutomationStartDropsAStopThatReachedIt() async {
        let rig = Rig()
        let gate = StartGate()
        rig.capture.duringStart = { await gate.wait() }
        rig.capture.startError = CaptureError.noInputDevice
        let start = Task { @MainActor in await rig.controller.startHandsFree() }
        await rig.settle()
        rig.controller.stopHandsFree()
        #expect(rig.controller.pendingAutomationEnd == .stop)
        gate.open()
        await start.value
        #expect(rig.controller.pendingAutomationEnd == nil && !rig.controller.automationStartPending)
    }

    @Test func aURLStartAndAKeyPressDuringACaptureStopBeginOneSession() async {
        for urlFirst in [true, false] {
            let rig = Rig()
            let gate = StartGate()
            await rig.lockIn()
            rig.capture.duringStop = { await gate.wait() }
            rig.controller.stopHandsFree()
            let before = rig.log.all.filter { $0 == "capture.start" }.count
            var tasks: [Task<Void, Never>] = []
            let url: @MainActor () -> Void = { tasks.append(Task { @MainActor in await rig.controller.startHandsFree() }) }
            let key: @MainActor () -> Void = { tasks.append(Task { @MainActor in await rig.controller.handle(.pressed(at: keyDown + 1)) }) }
            if urlFirst { url(); key() } else { key(); url() }
            await rig.settle()
            gate.open()
            for task in tasks { await task.value }
            await rig.settle()
            #expect(rig.log.all.filter { $0 == "capture.start" }.count == before + 1)
        }
    }

    @Test func aQuickFnTapDuringAURLStartCannotDiscardTheRecordingAndTheNextTapStopsIt() async {
        let rig = Rig()
        let gate = StartGate()
        let service = HotkeyService(options: .init(source: .fnFlag, configuration: .init(recordingMode: .hold)), otherKeysHeld: { _ in false })
        defer { service.stop() }
        rig.controller.onAutomationLock = { service.adoptLockedRecording() }
        let consumer = Task { @MainActor in await rig.controller.consume(service.events) }
        defer { consumer.cancel() }
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        rig.capture.duringStart = { await gate.wait() }

        let url = Task { @MainActor in await rig.controller.startHandsFree() }
        await rig.settle()
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 1_000_000))
        await rig.settle()
        gate.open()
        await url.value
        await rig.settle()
        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)

        // The release lands inside the minimum hold, which used to read as a discard.
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: 0, timestamp: 20_000_000))
        await rig.settle()
        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)
        #expect(rig.store.finishes.isEmpty)

        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 900_000_000))
        await rig.until { rig.controller.phase != .recording }
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
    }

    @Test func aDiscardNeverEndsAHandsFreeRecording() async {
        let rig = Rig()
        await rig.lockIn()
        await rig.controller.handle(.discarded(reason: .tooShort))
        #expect(rig.controller.phase == .recording && rig.controller.isHandsFree)
        #expect(rig.store.finishes.isEmpty)
    }

    @Test func anAutomationStartTellsTheHotkeySideButAKeyLockDoesNot() async {
        let rig = Rig()
        let told = Rig.Counter()
        rig.controller.onAutomationLock = { told.count += 1 }
        await rig.lockIn()
        #expect(told.count == 0)
        await rig.controller.cancelHandsFree()

        await rig.controller.startHandsFree()
        #expect(told.count == 1 && rig.controller.isHandsFree)
    }

    @Test func automationStartIsRefusedWhenBusyLoadingOrFailed() async {
        let busy = Rig()
        busy.controller.canStartRecording = { false }
        await busy.controller.startHandsFree()
        #expect(busy.controller.phase == .idle && !busy.log.contains("capture.start"))
        #expect(busy.pill.messages.map(\.headline) == ["Mouthtype is busy"])

        let loading = Rig()
        loading.engine.readiness = .loading
        await loading.controller.startHandsFree()
        #expect(loading.controller.phase == .idle && !loading.log.contains("capture.start"))

        let failed = Rig()
        failed.engine.readiness = .failed
        await failed.controller.startHandsFree()
        #expect(failed.controller.phase == .idle && !failed.log.contains("capture.start"))
    }

    @Test func automationToggleStopsAHandsFreeRecordingAndStartsWhenIdle() async {
        let rig = Rig()
        await rig.controller.toggleHandsFree()
        #expect(rig.controller.isHandsFree && rig.controller.phase == .recording)
        await rig.controller.toggleHandsFree()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle && !rig.controller.isHandsFree)
    }

    @Test func automationStartAndToggleLeaveAHeldKeyRecordingAlone() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        let before = rig.log.all
        await rig.controller.startHandsFree()
        await rig.controller.toggleHandsFree()
        #expect(rig.log.all == before)
        #expect(rig.controller.phase == .recording && !rig.controller.isHandsFree)
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
        #expect(rig.cards.presented == [.limitWarning(stopsAfter: 20 * 60)])
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
        #expect(rig.cards.presented.isEmpty)
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
        #expect(
            capturing == [
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

/// Holds a fake capture's start or stop until the test lets it go, so the ordering under test is fixed, not timed.
@MainActor
private final class StartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
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

@MainActor
@Suite struct NothingIsLostTests {
    private let shortLimits = DictationController.Limits(warningAfter: 3, stopAfter: 5, partialFlushEvery: 2)

    // MARK: Length limit

    @Test func aHeldRecordingWarnsThenStopsAtTheInjectedLimit() async {
        let rig = Rig(limits: shortLimits)
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()
        #expect(rig.clock.sleeperCount == 1)

        rig.clock.advance(by: 2.9)
        await rig.settle()
        #expect(rig.cards.presented.isEmpty && rig.controller.phase == .recording)

        rig.clock.advance(by: 0.1)
        await rig.settle()
        #expect(rig.cards.presented == [.limitWarning(stopsAfter: 5)])
        #expect(rig.cards.presented.first?.header == "One minute left\nRecording stops at 5 seconds")
        #expect(rig.controller.phase == .recording)

        rig.clock.advance(by: 1.9)
        await rig.settle()
        #expect(rig.controller.phase == .recording)

        rig.clock.advance(by: 0.1)
        await rig.settle()
        await rig.controller.waitForProcessing()
        await rig.until { rig.controller.phase == .idle }
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .idle)
        // The warning card came down when the recording stopped.
        #expect(rig.log.all.suffix(from: rig.log.index(of: "card.present:limitWarning")!).contains("card.dismiss"))
    }

    @Test func theStandardLimitIsNineteenAndTwentyMinutes() {
        #expect(DictationController.Limits.standard.warningAfter == 19 * 60)
        #expect(DictationController.Limits.standard.stopAfter == 20 * 60)
        #expect(DeliveryCard.limitWarning(stopsAfter: 20 * 60).header == "One minute left\nRecording stops at 20 minutes")
    }

    @Test func aReleaseBeforeTheWarningCancelsTheTimer() async {
        let rig = Rig(limits: shortLimits)
        await rig.dictate()
        await rig.settle()
        rig.clock.advance(by: 60)
        await rig.settle()
        #expect(rig.cards.presented.isEmpty && rig.clock.sleeperCount == 0)
    }

    // MARK: Saving a recording as it goes

    @Test func aRecordingInProgressIsSavedInPiecesAndTheCopyGoesWhenItEnds() async {
        let rig = Rig(limits: shortLimits, partials: true)
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()
        rig.capture.available = 16_000
        rig.clock.advance(by: 2)
        await rig.settle()
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)); await rig.settle() }
        #expect(rig.log.contains("archive.partial:16000"))

        rig.capture.available = 40_000
        rig.clock.advance(by: 2)
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)); await rig.settle() }
        // Only what the first piece didn't have.
        #expect(rig.log.contains("archive.partial:24000"))

        await rig.controller.handle(.released(at: keyUp))
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func discardingARecordingDropsItsInProgressCopy() async {
        let rig = Rig(limits: shortLimits, partials: true)
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        #expect(rig.log.contains("archive.discardPartial"))
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
    }

    @Test func updaterGatePreservesInterruptedAudioUntilWorkCanResume() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        let gate = Rig.Counter()
        rig.controller.canStartRecording = { gate.count == 1 }
        await rig.controller.insertInterrupted()
        #expect(!rig.log.contains("engine.transcribe") && rig.inserter.delivered.isEmpty)
        gate.count = 1
        await rig.controller.insertInterrupted()
        #expect(rig.inserter.delivered == ["Hello world."])
    }

    // MARK: Microphone lost

    @Test(arguments: [true, false], [true, false])
    func aMicrophoneLostDuringStartupStillOffersTheSavedTake(duringCaptureStart: Bool, prepared: Bool) async {
        let rig = Rig()
        rig.capture.isPrepared = prepared
        let interrupt: @MainActor @Sendable () async -> Void = {
            rig.capture.interrupt()
            rig.capture.interrupt()
            await rig.settle()
        }
        if duringCaptureStart { rig.capture.duringStart = interrupt } else { rig.store.duringBegin = interrupt }

        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()

        #expect(rig.cards.presented == [.micDisconnected(seconds: 2)])
        #expect(rig.controller.phase == .idle)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        #expect(rig.log.contains("store.recordCapture"))
        #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
        #expect(rig.finishedAttempts.count == 1)
        #expect(rig.clock.sleeperCount == 0)

        await rig.controller.handle(.released(at: keyUp))
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        rig.capture.duringStart = nil
        rig.store.duringBegin = nil
        rig.cards.click(.insert)
        await rig.until { !rig.inserter.delivered.isEmpty }
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world.", "Hello world."])
    }

    @Test func aFailedStartDoesNotLeaveADisconnectForTheNextTake() async {
        let rig = Rig()
        rig.capture.duringStart = {
            rig.capture.interrupt()
            await rig.settle()
        }
        rig.capture.startError = CaptureError.noInputDevice
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.controller.phase == .idle)
        #expect(rig.cards.presented.isEmpty && !rig.log.contains("capture.stop"))
        #expect(rig.store.finishes.map(\.0) == [.failed])
        rig.capture.duringStart = nil
        rig.capture.startError = nil
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.cards.presented.isEmpty)
    }

    @Test(arguments: [true, false], [true, false])
    func aLostMicrophoneRecoversTheSavedPartialWhenFinalizationFails(throwsOnStop: Bool, insert: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-interruption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive)
        await rig.controller.handle(.pressed(at: keyDown))
        let id = try #require(rig.store.start?.id)
        let samples = capturedTone().samples
        try archive.appendPartial(samples: samples, id: id)
        rig.capture.stopError = throwsOnStop ? Boom() : nil
        rig.capture.audio.samples = []

        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }

        #expect(rig.cards.presented.last == .micDisconnected(seconds: 2))
        #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.store.capture?.audioPath == archive.url(for: id).path)
        let restored = try? archive.read(id: id)
        #expect(restored?.count == samples.count)

        if insert {
            rig.cards.click(.insert)
            await rig.until { !rig.inserter.delivered.isEmpty }
            await rig.controller.waitForProcessing()
            #expect(rig.inserter.delivered == ["Hello world."])
        } else {
            await rig.controller.discardInterrupted()
            await rig.controller.insertInterrupted()
            await rig.controller.handle(.released(at: keyUp))
            #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
            #expect(rig.store.finishes.map(\.0) == [.failed, .cancelled])
        }
    }

    @Test func failedPartialRecoveryKeepsTheOriginalFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-interruption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive)
        await rig.controller.handle(.pressed(at: keyDown))
        let id = try #require(rig.store.start?.id)
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        let original = Data("incomplete WAV".utf8)
        try original.write(to: archive.partialURL(for: id))
        rig.capture.stopError = Boom()

        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }

        #expect(try Data(contentsOf: archive.partialURL(for: id)) == original)
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.cards.presented.isEmpty && rig.inserter.delivered.isEmpty)
        #expect(rig.pill.messages.last?.detail == "No audio could be recovered")
    }

    @Test(arguments: ["archive", "recordCapture"])
    func terminationRefusesFailedPreservationAndRetriesTheRetainedAudioWithoutStoppingTwice(failure: String) async {
        let archive = RetryArchive()
        let rig = Rig(archive: archive)
        await rig.controller.handle(.pressed(at: keyDown))
        if failure == "archive" { archive.setFailing(true) } else { rig.store.failing.insert(failure) }
        #expect(!(await rig.controller.prepareForTermination()))
        #expect(rig.inserter.delivered.isEmpty)
        await rig.controller.handle(.pressed(at: keyUp + 1))
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        archive.setFailing(false)
        rig.store.failing.removeAll()
        #expect(await rig.controller.prepareForTermination())
        #expect(archive.attempts == 2)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        #expect(rig.store.finishes.isEmpty)
    }

    @Test func terminationPreservesTheWholeActiveTakeBeforeTheFirstPartialFlush() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive, quietAudio: true, storeWriter: TranscriptStoreWriter(store: store))
        await rig.controller.handle(.pressed(at: keyDown))
        let id = try #require(try store.unfinished(from: .distantPast, before: .distantFuture).first?.id)
        #expect(!FileManager.default.fileExists(atPath: archive.partialURL(for: id).path))
        #expect(await rig.controller.prepareForTermination())
        #expect(try archive.read(id: id).count == capturedTone().samples.count)
        let row = try #require(try store.dictation(id: id))
        #expect(row.status == .recorded && row.audioPath == archive.url(for: id).path)
        #expect(try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: FakeClock.wall.addingTimeInterval(60)).map(\.id) == [id])
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        #expect(!rig.log.contains("engine.transcribe") && rig.inserter.delivered.isEmpty)
        #expect(rig.log.contains("audio.restore"))
        #expect(await rig.controller.prepareForTermination())
        await rig.controller.handle(.pressed(at: keyDown + 1))
        #expect(rig.log.all.filter { $0 == "capture.start" }.count == 1)
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func aTakeCutOffByQuitIsOfferedByTheNextLaunchScanAndThenEnded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-quit-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive, quietAudio: true, storeWriter: TranscriptStoreWriter(store: store))
        await rig.controller.handle(.pressed(at: keyDown))
        let id = try #require(try store.unfinished(from: .distantPast, before: .distantFuture).first?.id)
        #expect(await rig.controller.prepareForTermination())

        let relaunch = FakeClock.wall.addingTimeInterval(60)
        let scan = try DictationRecovery.scan(store: store, archive: archive, now: relaunch, launchedAt: relaunch)

        #expect(scan.newest?.id == id && scan.olderCount == 0 && scan.lostCount == 0)
        let row = try #require(try store.dictation(id: id))
        #expect(row.status == .failed && row.errorMessage == DictationRecovery.interruptedMessage)
        let again = try DictationRecovery.scan(store: store, archive: archive, now: relaunch, launchedAt: relaunch)
        #expect(again.newest == nil)
    }

    @Test(arguments: ["archive", "recordCapture"])
    func terminationRetriesUnsavedQueuedAudioBeforeAllowingQuit(failure: String) async throws {
        let archive = RetryArchive()
        let rig = Rig(archive: archive)
        rig.engine.holds = 1
        defer { rig.engine.releaseHeld() }
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        let queuedID = try #require(rig.store.start?.id)
        if failure == "archive" { archive.setFailing(true) } else { rig.store.failing.insert("recordCapture") }
        await rig.controller.handle(.released(at: keyUp + 2))
        await rig.until { rig.log.all.filter { $0 == "store.recordCapture" }.count == 2 }
        #expect(!(await rig.controller.prepareForTermination()))
        archive.setFailing(false)
        rig.store.failing.removeAll()
        #expect(await rig.controller.prepareForTermination())
        #expect(archive.savedIDs.contains(queuedID))
        #expect(archive.attempts >= 4)
        #expect(rig.store.capture?.audioPath == "/virtual/audio/\(queuedID).wav")
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered.isEmpty && rig.engine.samplesSeen.count == 1)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 2)
    }

    @Test func terminationAllowsQuitAfterStopFailsWithoutDeletingAnUnreadablePartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-quit-lost-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AudioArchive(supportDirectory: directory)
        let rig = Rig(archive: archive)
        await rig.controller.handle(.pressed(at: keyDown))
        let id = try #require(rig.store.start?.id)
        let partial = archive.partialURL(for: id)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data(repeating: 7, count: 80)
        try damaged.write(to: partial)
        rig.capture.stopError = Boom()
        #expect(await rig.controller.prepareForTermination())
        #expect(rig.controller.phase == .idle && rig.store.finishes.last?.0 == .failed)
        #expect(try Data(contentsOf: partial) == damaged)
        #expect(rig.inserter.delivered.isEmpty)
        #expect(await rig.controller.prepareForTermination())
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
    }

    @Test(arguments: [false, true])
    func terminationWithUnavailableHistoryStillArchivesTheActualAudio(missingStore: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-quit-no-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AudioArchive(supportDirectory: directory)
        let rig = Rig(withStore: !missingStore, archive: archive)
        if !missingStore { rig.store.failing.insert("begin") }
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(await rig.controller.prepareForTermination())
        let files = try FileManager.default.contentsOfDirectory(at: archive.url(for: "probe").deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let saved = try #require(files.first)
        #expect(try AudioArchive.read(contentsOf: saved).count == capturedTone().samples.count)
        #expect(rig.inserter.delivered.isEmpty)
    }

    @Test func terminationStillRequiresTheWavWhenHistoryIsUnavailable() async {
        let archive = RetryArchive()
        let rig = Rig(withStore: false, archive: archive)
        await rig.controller.handle(.pressed(at: keyDown))
        archive.setFailing(true)
        #expect(!(await rig.controller.prepareForTermination()))
        #expect(archive.savedIDs.isEmpty)
        archive.setFailing(false)
        #expect(await rig.controller.prepareForTermination())
        #expect(archive.savedIDs.count == 1 && archive.attempts == 2)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
    }

    @Test func terminationCanCloseAnEmptyCaptureWithoutInventingSavedAudio() async {
        var empty = capturedTone()
        empty.samples = []
        empty.audioMs = 0
        let rig = Rig(audio: empty)
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(await rig.controller.prepareForTermination())
        #expect(rig.store.finishes.last?.0 == .empty)
        #expect(!rig.log.contains("archive.write") && !rig.log.contains("engine.transcribe"))
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
    }

    @Test func terminationPreservesAnActiveTakeAndQueuedCapturesWithoutWaitingForTheEarlierModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-queued-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive, storeWriter: TranscriptStoreWriter(store: store))
        rig.engine.holds = 1
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        await rig.controller.handle(.pressed(at: keyUp + 1))
        await rig.controller.handle(.released(at: keyUp + 2))
        await rig.until { (try? store.unfinished(from: .distantPast, before: .distantFuture).filter { $0.audioPath != nil }.count) == 2 }
        await rig.controller.handle(.pressed(at: keyUp + 3))
        #expect(await rig.controller.prepareForTermination())
        let beforeRestart = try store.unfinished(from: .distantPast, before: .distantFuture)
        #expect(beforeRestart.count == 3 && beforeRestart.allSatisfy { $0.audioPath != nil })
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        let saved = try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: FakeClock.wall.addingTimeInterval(60))
        #expect(saved.count == 3)
        for item in saved { #expect(try archive.read(id: item.id).count == capturedTone().samples.count) }
        #expect(rig.engine.samplesSeen.count == 1 && rig.inserter.delivered.isEmpty)
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 3)
    }

    @Test func terminationDoesNotWaitForAStalledModelOrAllowItsLatePaste() async {
        let rig = Rig()
        rig.engine.holds = 1
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.engine.waitForHeld()
        #expect(await rig.controller.prepareForTermination())
        #expect(rig.log.contains("store.recordCapture"))
        rig.engine.releaseHeld()
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered.isEmpty)
        #expect(rig.store.finishes.isEmpty)
    }

    @Test func terminationDuringCaptureStartupWaitsForRegistrationAndKeepsTheTail() async throws {
        let rig = Rig()
        rig.controller.terminationWait = .seconds(600)
        var completion: Task<Bool, Never>?
        rig.capture.duringStart = {
            completion = Task { await rig.controller.prepareForTermination() }
            await rig.settle()
            #expect(!rig.log.contains("capture.stop"))
        }
        await rig.controller.handle(.pressed(at: keyDown))
        let pending = try #require(completion)
        #expect(await pending.value)
        #expect(rig.log.contains("store.recordCapture"))
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
        #expect(rig.clock.sleeperCount == 0)
        rig.capture.duringStart = nil
    }

    @Test func interruptedAudioStaysReachableAfterANewerCanceledCardWithoutExposingAnActiveTake() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-saved-interruption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let archive = AudioArchive(supportDirectory: dir)
        let rig = Rig(archive: archive, storeWriter: TranscriptStoreWriter(store: store))
        let launch = FakeClock.wall.addingTimeInterval(-60)
        await rig.controller.handle(.pressed(at: keyDown))
        let active = try #require(try store.unfinished(from: .distantPast, before: .distantFuture).first?.id)
        #expect(try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: launch).isEmpty)
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        #expect(try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: launch).map(\.id) == [active])
        await rig.controller.handle(.pressed(at: keyDown + 1))
        #expect(try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: launch).map(\.id) == [active])
        await rig.controller.handle(.cancelled(reason: .escape))
        #expect(rig.cards.presented.last?.kind == .cancelled)
        let saved = try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall, launchedAt: launch)
        #expect(saved.map(\.id) == [active])
        #expect(try archive.read(id: active).count == capturedTone().samples.count)
        #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
        _ = try DictationRecovery.scan(store: store, archive: archive, now: FakeClock.wall.addingTimeInterval(60), launchedAt: FakeClock.wall.addingTimeInterval(60))
        #expect(try DictationRecovery.saved(store: store, archive: archive, now: FakeClock.wall.addingTimeInterval(60), launchedAt: FakeClock.wall.addingTimeInterval(60)).map(\.id) == [active])
    }

    @Test func aLostMicrophoneKeepsTheAudioAndOffersInsertOrDiscard() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }

        let card = rig.cards.presented.last
        #expect(card == .micDisconnected(seconds: 2))
        #expect(card?.header == "Microphone disconnected\n2 seconds recorded")
        #expect(card?.actions == [.insert, .discard])
        let log = rig.log.all
        // The audio is on disk and the row says so before the card shows.
        #expect(log.firstIndex(of: "store.recordCapture")! < log.firstIndex(of: "card.present:micDisconnected")!)
        #expect(rig.controller.phase == .idle && rig.inserter.delivered.isEmpty)
        #expect(rig.store.finishes.map(\.0) == [.failed] && rig.log.contains("sound.error"))

        // The key coming up afterwards has nothing left to stop.
        await rig.controller.handle(.released(at: keyUp))
        #expect(rig.log.all.filter { $0 == "capture.stop" }.count == 1)
    }

    @Test func insertDeliversWhatWasCapturedThroughTheNormalPath() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        rig.cards.click(.insert)
        await rig.until { rig.controller.phase == .processing }
        await rig.controller.waitForProcessing()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.store.insertion?.finalText == "Hello world.")
        #expect(rig.controller.phase == .idle)
        #expect(rig.log.all.filter { $0 == "archive.write" }.count == 1)
    }

    @Test func discardEndsTheRowCancelled() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        rig.cards.click(.discard)
        await rig.settle()
        #expect(rig.store.finishes.map(\.0) == [.failed, .cancelled])
        #expect(rig.inserter.delivered.isEmpty && !rig.log.contains("engine.transcribe"))
        // A second click on a card that's gone does nothing.
        await rig.controller.insertInterrupted()
        #expect(rig.inserter.delivered.isEmpty)
    }

    @Test func aLostMicrophoneWithNothingCapturedFailsTheRow() async {
        let rig = Rig(
            audio: CapturedAudio(
                samples: [], sampleRate: 16_000, deviceUID: nil, deviceName: nil, deviceTransport: "usb",
                firstSampleMs: nil, firstNonzeroMs: nil, captureStartMs: 0, audioMs: 0
            ))
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.cards.presented.isEmpty)
        #expect(rig.pill.messages.first?.headline == "Microphone disconnected")
        #expect(rig.controller.phase == .idle)
    }

    @Test func aLostMicrophoneWhileLockedEndsTheLock() async {
        let rig = Rig()
        await rig.lockIn()
        rig.capture.interrupt()
        await rig.until { rig.cards.presented.last?.kind == .micDisconnected }
        #expect(!rig.controller.isHandsFree && rig.lockEnded.count == 1)
        #expect(rig.cards.presented.last?.kind == .micDisconnected)
    }

    @Test func aSavedRecordingStillInsertsWhileANewOneIsBeingSpoken() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        await rig.controller.handle(.pressed(at: keyDown + 50))
        #expect(rig.controller.phase == .recording)
        rig.cards.click(.insert)
        await rig.until { !rig.inserter.delivered.isEmpty }
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.controller.phase == .recording)
    }
}

@MainActor @Suite struct QuietRecordingLifecycleTests {
    @Test func startCueFinishesBeforeMuteWithoutDelayingCapture() async throws {
        let rig = Rig(quietAudio: true)
        rig.sounds.startCueDuration = 0.2
        rig.sounds.isStartCuePlaying = true
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.log.contains("capture.start"))
        #expect(rig.log.contains("sound.start"))
        #expect(!rig.log.contains("audio.quiet"))
        await rig.settle()
        rig.clock.advance(by: 0.2)
        await rig.settle()
        #expect(!rig.log.contains("audio.quiet"))
        rig.sounds.isStartCuePlaying = false
        rig.clock.advance(by: 0.05)
        await rig.until { rig.log.contains("audio.quiet") }
        #expect(rig.log.all.filter { $0 == "audio.quiet" }.count == 1)
        let sound = try #require(rig.log.index(of: "sound.start"))
        let mute = try #require(rig.log.index(of: "audio.quiet"))
        #expect(sound < mute)
        await rig.controller.handle(.discarded(reason: .tooShort))
    }

    @Test(arguments: [HotkeyEvent.released(at: keyUp), .cancelled(reason: .escape), .discarded(reason: .tooShort)])
    func endingBeforeCueCompletionNeverMutesLater(_ event: HotkeyEvent) async {
        let rig = Rig(quietAudio: true)
        rig.sounds.startCueDuration = 0.2
        rig.sounds.isStartCuePlaying = true
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()
        await rig.controller.handle(event)
        await rig.controller.waitForProcessing()
        rig.sounds.isStartCuePlaying = false
        rig.clock.advance(by: 1)
        await rig.settle()
        #expect(!rig.log.contains("audio.quiet"))
    }

    @Test func olderCueDelayCannotMuteANewerTake() async {
        let rig = Rig(quietAudio: true)
        rig.sounds.startCueDuration = 0.2
        rig.sounds.isStartCuePlaying = true
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()
        await rig.controller.handle(.discarded(reason: .tooShort))
        rig.sounds.startCueDuration = 0.5
        await rig.controller.handle(.pressed(at: keyUp + 1_000_000_000))
        await rig.settle()
        rig.clock.advance(by: 0.2)
        await rig.settle()
        #expect(!rig.log.contains("audio.quiet"))
        rig.sounds.isStartCuePlaying = false
        rig.clock.advance(by: 0.3)
        await rig.until { rig.log.contains("audio.quiet") }
        #expect(rig.log.all.filter { $0 == "audio.quiet" }.count == 1)
        await rig.controller.handle(.discarded(reason: .tooShort))
    }

    @Test func cueThatDoesNotFinishSkipsMuteAfterBoundedWait() async {
        let rig = Rig(quietAudio: true)
        rig.sounds.startCueDuration = 0.2
        rig.sounds.isStartCuePlaying = true
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.settle()
        rig.clock.advance(by: 0.2)
        await rig.settle()
        for _ in 0..<20 {
            rig.clock.advance(by: 0.05)
            await rig.settle()
        }
        rig.sounds.isStartCuePlaying = false
        rig.clock.advance(by: 5)
        await rig.settle()
        #expect(!rig.log.contains("audio.quiet"))
        await rig.controller.handle(.discarded(reason: .tooShort))
    }

    @Test(arguments: [HotkeyEvent.released(at: keyUp), .cancelled(reason: .escape), .discarded(reason: .tooShort)])
    func restoresAtCaptureEndBeforeProcessing(_ event: HotkeyEvent) async throws {
        let rig = Rig(quietAudio: true)
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.log.contains("audio.quiet"))
        #expect(!rig.log.contains("audio.restore"))
        await rig.controller.handle(event)
        await rig.controller.waitForProcessing()
        #expect(rig.log.all.filter { $0 == "audio.quiet" }.count == 1)
        #expect(rig.log.all.filter { $0 == "audio.restore" }.count == 1)
        if let stop = rig.log.index(of: "capture.stop"), let restore = rig.log.index(of: "audio.restore") {
            #expect(restore > stop)
        }
        if let restore = rig.log.index(of: "audio.restore"), let transcribe = rig.log.index(of: "engine.transcribe") {
            #expect(restore < transcribe)
        }
    }

    @Test func failedStartNeverQuietsAndFailedStopRestores() async {
        let start = Rig(quietAudio: true)
        start.capture.startError = Boom()
        await start.controller.handle(.pressed(at: keyDown))
        #expect(!start.log.contains("audio.quiet"))
        let stop = Rig(quietAudio: true)
        stop.capture.stopError = Boom()
        await stop.controller.handle(.pressed(at: keyDown))
        await stop.controller.handle(.released(at: keyUp))
        await stop.controller.waitForProcessing()
        #expect(stop.log.all.filter { $0 == "audio.restore" }.count == 1)
    }

    @Test func olderProcessingFailureDoesNotRestoreANewerRecording() async {
        let rig = Rig(quietAudio: true)
        rig.engine.holds = 1
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.released(at: keyUp))
        await rig.until { rig.log.contains("engine.transcribe") }
        await rig.controller.handle(.pressed(at: keyUp + 1_000_000_000))
        rig.engine.error = Boom()
        rig.engine.releaseHeld()
        await rig.until { rig.finishedAttempts.count == 1 }
        #expect(rig.controller.phase == .recording)
        #expect(rig.log.all.filter { $0 == "audio.quiet" }.count == 2)
        #expect(rig.log.all.filter { $0 == "audio.restore" }.count == 1)
        await rig.controller.handle(.discarded(reason: .tooShort))
        #expect(rig.log.all.filter { $0 == "audio.restore" }.count == 2)
    }

    @Test func interruptionAndLengthLimitRestore() async {
        let rig = Rig(quietAudio: true)
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        for _ in 0..<100 where !rig.log.contains("audio.restore") { await Task.yield() }
        #expect(rig.log.all.filter { $0 == "audio.restore" }.count == 1)
        let limited = Rig(limits: .init(warningAfter: 1, stopAfter: 2, partialFlushEvery: 5), quietAudio: true)
        await limited.controller.handle(.pressed(at: keyDown))
        for _ in 0..<100 where limited.clock.sleeperCount == 0 { await Task.yield() }
        limited.clock.advance(by: 1)
        for _ in 0..<100 where limited.clock.sleeperCount == 0 { await Task.yield() }
        limited.clock.advance(by: 1)
        for _ in 0..<100 where !limited.log.contains("audio.restore") { await Task.yield() }
        await limited.controller.waitForProcessing()
        #expect(limited.log.all.filter { $0 == "audio.restore" }.count == 1)
    }
}

@MainActor
@Suite struct SendAfterInsertControllerTests {
    @Test func aNormalTakeAsksForOneReturnAfterDelivery() async {
        let rig = Rig()
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.inserter.returnsPressed.count == 1)
        #expect(rig.inserter.returnsPressed.first?.finalText == "Hello world.")
    }

    @Test func undoNeverAsksForAReturn() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))
        await rig.settle()
        await rig.controller.undoCancel()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.inserter.returnsPressed.isEmpty)
    }

    @Test func aSavedInterruptedTakeNeverAsksForAReturn() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        rig.capture.interrupt()
        await rig.until { rig.controller.phase == .idle }
        await rig.controller.insertInterrupted()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.inserter.returnsPressed.isEmpty)
    }
}

@MainActor
@Suite struct SendAfterInsertSalvageTests {
    @Test func aSalvagedTakeNeverAsksForAReturn() async {
        let rig = Rig()
        rig.capture.audio.wasInterrupted = true
        await rig.dictate()
        #expect(rig.inserter.delivered == ["Hello world."])
        #expect(rig.inserter.returnsPressed.isEmpty)
    }
}
