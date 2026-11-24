import AVFoundation
import Foundation
import MouthtypeCore
import Synchronization
import Testing
@testable import MouthtypeMac

/// One shared microphone, three consumers: each start takes a lease, and only the lease that started can stop or cancel.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CaptureOwnershipTests {
    private func shared() -> (OwnershipInputDriver, MicCapture) {
        let driver = OwnershipInputDriver()
        let capture = AudioCapture(
            input: driver, resolveInput: { .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false) })
        return (driver, MicCapture(capture: capture))
    }

    private func setupTake(_ capture: MicCapture) -> SetupTestTake {
        SetupTestTake(
            capture: capture, engine: OwnershipEngine(), readLevel: { -20 }, language: { .english },
            sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    }

    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private func isBusy(_ error: (any Error)?, heldBy owner: CaptureOwner) -> Bool {
        if case CaptureError.busy(let holder)? = error { return holder == owner }
        return false
    }

    @Test func aSecondStartWhileRecordingThrowsBusyAndLeavesTheFirstRunning() async throws {
        let driver = OwnershipInputDriver()
        let capture = AudioCapture(
            input: driver, resolveInput: { .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false) })
        let first = CaptureLease(owner: .setupTest)
        try await capture.start(keyDownAtNanos: HostClock.now(), lease: first)
        try driver.deliver()
        var refusal: (any Error)?
        do { try await capture.start(keyDownAtNanos: HostClock.now(), lease: CaptureLease(owner: .dictation)) } catch { refusal = error }
        #expect(isBusy(refusal, heldBy: .setupTest))
        // The same consumer asking again is refused too: one lease, one recording.
        await #expect(throws: CaptureError.self) { try await capture.start(keyDownAtNanos: HostClock.now(), lease: first) }
        #expect(driver.counts.withLock { $0.starts } == 1)
        #expect(driver.counts.withLock { $0.stops } == 0)
        let audio = try await capture.stop(first)
        #expect(audio.samples.count > 10_000)
    }

    @Test func stopAndCancelByANonOwnerLeaveTheOwnerRecording() async throws {
        let driver = OwnershipInputDriver()
        let capture = AudioCapture(
            input: driver, resolveInput: { .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false) })
        let owner = CaptureLease(owner: .dictation), other = CaptureLease(owner: .setupTest)
        // Two leases for one consumer are still two recordings: a stale one must not end the live one.
        let stale = CaptureLease(owner: .dictation)
        try await capture.start(keyDownAtNanos: HostClock.now(), lease: owner)
        try driver.deliver()
        for lease in [other, stale] {
            await #expect(throws: CaptureError.self) { try await capture.stop(lease) }
            await #expect(throws: CaptureError.self) { try await capture.stop(lease, salvaging: true) }
            #expect(await !capture.cancel(lease))
            #expect(await capture.partialSamples(from: 0, lease: lease).isEmpty)
            #expect(await capture.previewSnapshot(maxSamples: 16_000, lease: lease).samples.isEmpty)
        }
        #expect(driver.counts.withLock { $0.stops } == 0)
        #expect(await !capture.partialSamples(from: 0, lease: owner).isEmpty)
        try driver.deliver()
        let audio = try await capture.stop(owner)
        #expect(audio.samples.count > 25_000)
        #expect(driver.counts.withLock { $0.stops } == 1)
    }

    @Test func dictationDuringASetupTestTakeIsRefusedAndTheTakeKeepsItsAudio() async throws {
        let (driver, dictation) = shared()
        let take = setupTake(dictation.owned(by: .setupTest))
        take.start()
        await wait { driver.counts.withLock { $0.starts } == 1 }
        #expect(dictation.holder == .setupTest)
        try driver.deliver()

        var refusal: (any Error)?
        do { try await dictation.start(keyDownAtNanos: HostClock.now()) } catch { refusal = error }
        #expect(isBusy(refusal, heldBy: .setupTest))
        #expect(DictationController.pillMessage(for: try #require(refusal)) == DictationController.busyMessage)
        // What a refused dictation does next must not reach the take: its failure path cancels the capture.
        await dictation.cancel()
        await #expect(throws: CaptureError.self) { try await dictation.stop() }
        await #expect(throws: CaptureError.self) { try await dictation.stopSalvaging() }
        #expect(await dictation.partialSamples(from: 0).isEmpty)
        #expect(driver.counts.withLock { $0.stops } == 0)
        #expect(dictation.holder == .setupTest)
        // The refusal leaves the microphone's readiness alone.
        #expect(dictation.isPrepared)
        #expect(dictation.preparation.error == nil)

        try driver.deliver()
        take.stop()
        await wait { !take.isBusy }
        guard case .finished(let outcome) = take.state else {
            Issue.record("the take lost its audio: \(take.state)")
            return
        }
        #expect(outcome.peakDb > -10)
        #expect(driver.counts.withLock { $0.starts } == 1)
        #expect(dictation.holder == nil)
        // With the take over, dictation gets the microphone.
        try await dictation.start(keyDownAtNanos: HostClock.now())
        #expect(dictation.holder == .dictation)
        await dictation.cancel()
        #expect(dictation.holder == nil)
    }

    @Test func aSetupTestTakeDuringDictationIsRefusedAndDictationKeepsItsAudio() async throws {
        let (driver, dictation) = shared()
        try await dictation.start(keyDownAtNanos: HostClock.now())
        try driver.deliver()

        let take = setupTake(dictation.owned(by: .setupTest))
        take.start()
        await wait { !take.isBusy }
        #expect(take.state == .failed(SetupTestTake.busyMessage))
        // Closing the setup window cancels the take; that must not reach the dictation either.
        await take.cancel()
        #expect(driver.counts.withLock { $0.starts } == 1)
        #expect(driver.counts.withLock { $0.stops } == 0)
        #expect(dictation.holder == .dictation)

        try driver.deliver()
        let audio = try await dictation.stop()
        #expect(audio.samples.count > 25_000)
        #expect(dictation.holder == nil)
    }

    @Test func aVoiceEditDuringDictationIsRefused() async throws {
        let (driver, dictation) = shared()
        try await dictation.start(keyDownAtNanos: HostClock.now())
        try driver.deliver()

        let recorder = VoiceInstructionRecorder(capture: dictation.owned(by: .voiceEdit), engine: OwnershipEngine(), language: { .english })
        var refusal: (any Error)?
        do { try await recorder.start() } catch { refusal = error }
        #expect(isBusy(refusal, heldBy: .dictation))
        await recorder.cancel()
        #expect(try await recorder.finish().isEmpty)
        #expect(driver.counts.withLock { $0.stops } == 0)
        #expect(dictation.holder == .dictation)

        let audio = try await dictation.stop()
        #expect(audio.samples.count > 10_000)
    }

    @Test func dictationDuringAVoiceEditIsRefusedAndTheInstructionIsKept() async throws {
        let (driver, dictation) = shared()
        let engine = OwnershipEngine()
        let recorder = VoiceInstructionRecorder(capture: dictation.owned(by: .voiceEdit), engine: engine, language: { .english })
        try await recorder.start()
        try driver.deliver()
        await #expect(throws: CaptureError.self) { try await dictation.start(keyDownAtNanos: HostClock.now()) }
        await dictation.cancel()
        #expect(driver.counts.withLock { $0.stops } == 0)
        #expect(try await recorder.finish() == "heard")
        #expect(engine.calls == 1)
        #expect(dictation.holder == nil)
    }

    @Test func theMicrophoneIsFreeAgainAfterAStopACancelAndAFailedStart() async throws {
        let (driver, dictation) = shared()
        let setup = dictation.owned(by: .setupTest)
        try await dictation.start(keyDownAtNanos: HostClock.now())
        _ = try await dictation.stop()
        try await setup.start(keyDownAtNanos: HostClock.now())
        await setup.cancel()
        driver.fails.withLock { $0 = true }
        await #expect(throws: CaptureError.self) { try await dictation.start(keyDownAtNanos: HostClock.now()) }
        #expect(dictation.holder == nil)
        driver.fails.withLock { $0 = false }
        try await setup.start(keyDownAtNanos: HostClock.now())
        #expect(dictation.holder == .setupTest)
        // A stop that throws still ends the recording, so it frees the microphone too.
        driver.interrupt()
        await #expect(throws: CaptureError.self) { try await setup.stop() }
        #expect(dictation.holder == nil)
    }

    @Test func aCancelRacingItsOwnStartNeverLeavesTheClaimAndTheInputDisagreeing() async throws {
        for _ in 0..<50 {
            let (driver, dictation) = shared()
            async let started: Void = dictation.start(keyDownAtNanos: HostClock.now())
            await Task.yield()
            await dictation.cancel()
            try await started
            let running = driver.counts.withLock { $0.starts - $0.stops } == 1
            #expect((dictation.holder == .dictation) == running)
            await dictation.cancel()
            #expect(dictation.holder == nil)
            #expect(driver.counts.withLock { $0.starts == $0.stops })
        }
    }
}

private final class OwnershipInputDriver: CaptureInputDriving {
    struct Counts {
        var starts = 0
        var stops = 0
    }
    let counts = Mutex(Counts())
    let fails = Mutex(false)
    private let sink = Mutex<InputSink?>(nil)

    func prepare(device: InputDevice, followsDefault: Bool) throws {}
    func start(device: InputDevice, followsDefault: Bool, sink: InputSink) throws -> InputDevice {
        if fails.withLock({ $0 }) { throw CaptureError.selectedMicrophoneUnavailable }
        counts.withLock { $0.starts += 1 }
        self.sink.withLock { $0 = sink }
        return device
    }
    func stop() {
        counts.withLock { $0.stops += 1 }
        sink.withLock { $0 = nil }
    }

    /// One second of a 440 Hz tone at the device's rate.
    func deliver() throws {
        let pcm = try makePCM(sampleRate: 48_000, channels: 1, frames: 48_000)
        let now = HostClock.now()
        sink.withLock { $0 }?.deliver(pcm, now, now)
    }
    func interrupt() { sink.withLock { $0 }?.routeChanged() }
}

@MainActor
private final class OwnershipEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    var calls = 0
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        try await transcribe(samples: samples)
    }
    func transcribe(samples: [Float]) async throws -> Transcription {
        calls += 1
        return Transcription(text: "heard", processingSeconds: 0, engineID: "fake")
    }
    func setVocabularyBias(_ bias: VocabularyBias?) async {}
}
