import Foundation
import Observation
import Synchronization
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct MicCaptureReadinessTests {
    @Test func successfulExplicitStartRecoversFailedPreparation() async throws {
        let driver = ReadinessInputDriver()
        let capture = MicCapture(
            capture: AudioCapture(
                input: driver,
                resolveInput: {
                    .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false)
                }))
        driver.fails.withLock { $0 = true }
        await #expect(throws: CaptureError.self) { try await capture.prepare() }
        #expect(!capture.isPrepared)
        driver.fails.withLock { $0 = false }
        try await capture.start(keyDownAtNanos: HostClock.now())
        #expect(capture.isPrepared)
        await capture.cancel()
    }

    @Test func failedExplicitStartClearsPreviouslyReadyInput() async throws {
        let driver = ReadinessInputDriver()
        let capture = MicCapture(
            capture: AudioCapture(
                input: driver,
                resolveInput: {
                    .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false)
                }))
        #expect(try await capture.prepare())
        driver.fails.withLock { $0 = true }
        await #expect(throws: CaptureError.self) { try await capture.start(keyDownAtNanos: HostClock.now()) }
        #expect(!capture.isPrepared)
    }

    @Test func setupObservesTheCaptureResultAndSelectionInvalidation() async throws {
        let driver = ReadinessInputDriver()
        let capture = MicCapture(
            capture: AudioCapture(
                input: driver,
                resolveInput: {
                    .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false)
                }))
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: EngineHost(), microphone: capture.preparation)
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.captureReady
        } onChange: {
            changed.withLock { $0 = true }
        }
        try await capture.start(keyDownAtNanos: HostClock.now())
        #expect(model.captureReady)
        #expect(changed.withLock { $0 })
        await capture.cancel()
        driver.fails.withLock { $0 = true }
        await #expect(throws: CaptureError.self) { try await capture.start(keyDownAtNanos: HostClock.now()) }
        #expect(!model.captureReady)
        #expect(model.captureError != nil)
        driver.fails.withLock { $0 = false }
        try await capture.start(keyDownAtNanos: HostClock.now())
        #expect(model.captureReady)
        #expect(model.captureError == nil)
        await capture.cancel()
        capture.invalidatePreparation()
        #expect(!model.captureReady)
    }

    @Test func interruptionInvalidatesReadinessBeforeNotifyingTheController() async throws {
        let driver = ReadinessInputDriver()
        let capture = MicCapture(
            capture: AudioCapture(
                input: driver,
                resolveInput: {
                    .init(device: .init(sampleRate: 48_000, channels: 1, id: 99), followsDefault: false)
                }))
        try await capture.start(keyDownAtNanos: HostClock.now())
        #expect(capture.isPrepared)
        await withCheckedContinuation { continuation in
            capture.onInterrupted = {
                #expect(!capture.isPrepared)
                continuation.resume()
            }
            Task.detached { driver.interrupt() }
        }
        #expect(!capture.isPrepared)
        capture.onInterrupted = nil
        await capture.cancel()
    }
}

private final class ReadinessInputDriver: CaptureInputDriving {
    let fails = Mutex(false)
    private let sink = Mutex<InputSink?>(nil)
    func prepare(device: InputDevice, followsDefault: Bool) throws {
        if fails.withLock({ $0 }) { throw CaptureError.selectedMicrophoneUnavailable }
    }
    func start(device: InputDevice, followsDefault: Bool, sink: InputSink) throws -> InputDevice {
        try prepare(device: device, followsDefault: followsDefault)
        self.sink.withLock { $0 = sink }
        return device
    }
    func interrupt() { sink.withLock { $0 }?.routeChanged() }
    func stop() { sink.withLock { $0 = nil } }
}
