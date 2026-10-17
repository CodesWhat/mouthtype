import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MouthtypeMac

@Suite struct CaptureInputSelectionTests {
    private func selected(_ id: UInt32, followsDefault: Bool = false) -> CaptureInputSelection {
        .init(device: .init(sampleRate: 48_000, channels: 1, id: id), followsDefault: followsDefault)
    }

    @Test func prepareAndStartUseTheResolvedExplicitInput() async throws {
        let driver = SelectionInputDriver()
        let input = selected(99)
        let capture = AudioCapture(input: driver, resolveInput: { input })
        try await capture.prepare()
        try await capture.start(keyDownAtNanos: HostClock.now())
        await capture.cancel()
        #expect(driver.state.withLock { $0.prepared } == [input])
        #expect(driver.state.withLock { $0.started } == [input])
        #expect(driver.state.withLock { $0.stops } == 1)
    }

    @Test func changesDuringRecordingWaitForTheNextTake() async throws {
        let driver = SelectionInputDriver()
        let choice = Mutex(selected(99))
        let capture = AudioCapture(input: driver, resolveInput: { choice.withLock { $0 } })
        try await capture.start(keyDownAtNanos: HostClock.now())
        choice.withLock { $0 = selected(100) }
        try await capture.prepare()
        #expect(driver.state.withLock { $0.prepared.isEmpty })
        #expect(driver.state.withLock { $0.started } == [selected(99)])
        await capture.cancel()
        try await capture.start(keyDownAtNanos: HostClock.now())
        await capture.cancel()
        #expect(driver.state.withLock { $0.started } == [selected(99), selected(100)])
    }

    @Test func missingChosenInputNeverStartsAnotherMicrophone() async {
        let driver = SelectionInputDriver()
        let capture = AudioCapture(input: driver, resolveInput: { throw CaptureError.selectedMicrophoneUnavailable })
        await #expect(throws: CaptureError.self) { try await capture.start(keyDownAtNanos: HostClock.now()) }
        #expect(driver.state.withLock { $0.started.isEmpty })
    }

    @Test func permissionIsCheckedBeforeDeviceSelection() async {
        let driver = SelectionInputDriver()
        let capture = AudioCapture(input: driver, resolveInput: {
            Issue.record("must not resolve a device without permission")
            throw CaptureError.noInputDevice
        }, authorization: { .denied })
        await #expect(throws: CaptureError.self) { try await capture.start(keyDownAtNanos: HostClock.now()) }
        #expect(driver.state.withLock { $0.started.isEmpty })
    }
}

private final class SelectionInputDriver: CaptureInputDriving {
    struct State {
        var prepared: [CaptureInputSelection] = []
        var started: [CaptureInputSelection] = []
        var stops = 0
    }
    let state = Mutex(State())
    func prepare(device: InputDevice, followsDefault: Bool) throws {
        state.withLock { $0.prepared.append(.init(device: device, followsDefault: followsDefault)) }
    }
    func start(device: InputDevice, followsDefault: Bool, sink: InputSink) throws -> InputDevice {
        state.withLock { $0.started.append(.init(device: device, followsDefault: followsDefault)) }
        return device
    }
    func stop() { state.withLock { $0.stops += 1 } }
}
