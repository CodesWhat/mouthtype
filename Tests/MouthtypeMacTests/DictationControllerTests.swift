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
    private(set) var finishes: [(DictationStatus, String?)] = []

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
}

@MainActor
private final class FakePill: DictationPill {
    let log: CallLog
    var messages: [String] = []

    init(log: CallLog) {
        self.log = log
    }

    func showRecording() { log.add("pill.recording") }
    func showProcessing() { log.add("pill.processing") }
    func showMessage(_ text: String, duration: TimeInterval) {
        messages.append(text)
        log.add("pill.message:\(text)")
    }
    func hide() { log.add("pill.hide") }
}

@MainActor
private final class FakeSounds: SoundPlayer {
    let log: CallLog

    init(log: CallLog) {
        self.log = log
    }

    func playStart() { log.add("sound.start") }
    func playStop() { log.add("sound.stop") }
    func playError() { log.add("sound.error") }
}

private final class FakeClock: DictationClock, @unchecked Sendable {
    static let wall = Date(timeIntervalSince1970: 1_791_806_400)
    private let lock = NSLock()
    private var host: UInt64

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
}

private let keyDown: UInt64 = 5_000_000_000
private let keyUp: UInt64 = 7_000_000_000

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
    let controller: DictationController
    var finishedAttempts: Counter

    final class Counter {
        var count = 0
    }

    init(audio: CapturedAudio = capturedTone(), withStore: Bool = true) {
        capture = FakeCapture(log: log, audio: audio)
        engine = FakeEngine(log: log)
        store = FakeStore(log: log)
        inserter = FakeInserter(log: log)
        pill = FakePill(log: log)
        sounds = FakeSounds(log: log)
        let clock = FakeClock(start: keyUp)
        let pipeline = DictationPipeline(
            store: withStore ? store : nil, archive: FakeArchive(log: log), engine: engine, clock: clock
        )
        controller = DictationController(
            capture: capture, engine: engine, pipeline: pipeline, inserter: inserter, pill: pill, sounds: sounds, clock: clock
        )
        let counter = Counter()
        finishedAttempts = counter
        controller.onAttemptFinished = { counter.count += 1 }
    }

    func dictate() async {
        await controller.handle(.pressed(at: keyDown))
        await controller.handle(.released(at: keyUp))
        await controller.waitForProcessing()
    }
}

@MainActor
@Suite struct DictationControllerTests {
    @Test func happyPathRunsTheCollaboratorsInOrder() async throws {
        let rig = Rig()
        await rig.dictate()

        #expect(rig.log.all == [
            "inserter.snapshot", "capture.start", "sound.start", "pill.recording", "store.begin",
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

    @Test func escapeCancelsWithAMessage() async {
        let rig = Rig()
        await rig.controller.handle(.pressed(at: keyDown))
        await rig.controller.handle(.cancelled(reason: .escape))

        #expect(rig.log.contains("capture.cancel"))
        #expect(rig.store.finishes.map(\.0) == [.cancelled])
        #expect(rig.pill.messages == ["Cancelled"])
        #expect(!rig.log.contains("engine.transcribe"))
        #expect(rig.controller.phase == .idle)
    }

    @Test func pressWhileTheEngineLoadsOnlyShowsAMessage() async {
        let rig = Rig()
        rig.engine.readiness = .loading
        await rig.controller.handle(.pressed(at: keyDown))
        #expect(rig.log.all == ["pill.message:Loading model\u{2026}"])
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
        #expect(rig.pill.messages == ["Still working on the last one"])

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
        #expect(rig.pill.messages == ["No microphone found"])
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
        #expect(rig.pill.messages == ["Microphone changed, try again"])
        #expect(rig.controller.phase == .idle)
    }

    @Test func engineErrorEndsFailedAndReturnsToIdle() async {
        let rig = Rig()
        rig.engine.error = Boom()
        await rig.dictate()

        #expect(rig.store.finishes.map(\.0) == [.failed])
        #expect(rig.pill.messages == ["Transcription failed"])
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

    @Test func aNonPastedResultShowsItsMessage() async {
        let rig = Rig()
        rig.inserter.result = DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: true, target: nil, finalText: "")
        await rig.dictate()
        #expect(rig.pill.messages == ["Secure field, not pasted"])
        #expect(rig.store.insertion?.outcome == "secure discard" && rig.store.insertion?.focusMoved == true)
    }
}
