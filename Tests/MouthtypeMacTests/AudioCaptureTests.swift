import AVFoundation
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct AudioCaptureTests {
    private struct Boom: Error {}

    @Test func captureErrorsAreOneLineMessages() {
        let errors: [CaptureError] = [
            .microphoneDenied, .microphonePending, .noInputDevice,
            .invalidInputFormat(sampleRate: 0, channels: 0),
            .engineStartFailed(Boom()), .routeChanged, .notRecording,
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.userMessage.contains("\n"))
        }
        #expect(CaptureError.microphoneDenied.userMessage == "microphone access denied: System Settings \u{2192} Privacy & Security \u{2192} Microphone")
    }

    @Test func microphoneStatusGatesCapture() {
        #expect(MicrophoneAccess.captureError(for: .authorized) == nil)
        for status in [AVAuthorizationStatus.denied, .restricted] {
            guard case .microphoneDenied? = MicrophoneAccess.captureError(for: status) else {
                Issue.record("expected microphoneDenied for \(status.rawValue)")
                continue
            }
        }
        guard case .microphonePending? = MicrophoneAccess.captureError(for: .notDetermined) else {
            Issue.record("expected microphonePending")
            return
        }
    }

    @Test func menuStatusText() {
        #expect(MicrophoneAccess.statusText(for: .authorized) == "Microphone: allowed")
        #expect(MicrophoneAccess.statusText(for: .denied) == "Microphone: not allowed")
        #expect(MicrophoneAccess.statusText(for: .restricted) == "Microphone: not allowed")
        #expect(MicrophoneAccess.statusText(for: .notDetermined) == "Microphone: not asked")
    }

    @Test func stopWithoutStartThrowsAndCancelWhenIdleIsSafe() async {
        let capture = AudioCapture()
        await #expect(throws: CaptureError.self) { try await capture.stop() }
        await capture.cancel()
        #expect(capture.level == 0)
    }

    @Test func levelMeterMapsDecibelsAndDecays() {
        let meter = LevelMeter()
        #expect(meter.value == 0)
        meter.update(rms: 1)
        #expect(meter.value == 1)
        meter.update(rms: 0)
        #expect(abs(meter.value - (1 - LevelMeter.decay)) < 1e-6)
        meter.reset()
        meter.update(rms: 0.001)   // -60 dBFS
        #expect(meter.value == 0)
        meter.update(rms: 0.0316)  // -30 dBFS
        #expect(abs(meter.value - 0.5) < 0.01)
    }

    @Test func selfTestArgument() {
        #expect(CaptureSelfTest.seconds(in: ["Mouthtype"]) == nil)
        #expect(CaptureSelfTest.seconds(in: ["Mouthtype", "--capture-selftest", "2.5"]) == 2.5)
        #expect(CaptureSelfTest.seconds(in: ["Mouthtype", "--capture-selftest"]) == 2)
        #expect(CaptureSelfTest.seconds(in: ["Mouthtype", "--capture-selftest", "abc"]) == 2)
        #expect(CaptureSelfTest.seconds(in: ["Mouthtype", "--capture-selftest", "999"]) == 2)
    }

    @Test func transportNames() {
        #expect(InputDevice.transportName(kAudioDeviceTransportTypeBuiltIn) == "built-in")
        #expect(InputDevice.transportName(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
        #expect(InputDevice.transportName(kAudioDeviceTransportTypeUSB) == "usb")
        #expect(InputDevice.transportName(0) == "other")
    }
}
