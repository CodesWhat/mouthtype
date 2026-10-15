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
        #expect(capture.reading == .silence)
    }

    @Test func levelMeterReportsDecibelsAndSplitsBands() {
        let meter = LevelMeter()
        #expect(meter.reading == .silence)
        func sine(_ hz: Float, amplitude: Float, count: Int = 1_600) -> [Float] {
            (0..<count).map { amplitude * sin(2 * .pi * hz * Float($0) / LevelMeter.sampleRate) }
        }
        meter.update(rms: 1)
        #expect(meter.reading.db == 0)
        meter.update(rms: 0.0316)  // -30 dBFS
        #expect(abs(meter.reading.db + 30) < 0.1)
        meter.update(rms: 0)
        #expect(meter.reading.db == LevelReading.floorDb)

        // A 150 Hz tone sits in the low band, 1 kHz in the mid band, 7 kHz in the high band.
        meter.reset()
        meter.update(samples: sine(150, amplitude: 0.1) + sine(150, amplitude: 0.1))
        var r = meter.reading
        #expect(r.low > r.mid + 3 && r.low > r.high + 12)
        meter.reset()
        meter.update(samples: sine(1_000, amplitude: 0.1) + sine(1_000, amplitude: 0.1))
        r = meter.reading
        #expect(r.mid > r.low + 12 && r.mid > r.high + 6)
        meter.reset()
        meter.update(samples: sine(7_000, amplitude: 0.1) + sine(7_000, amplitude: 0.1))
        r = meter.reading
        #expect(r.high > r.mid + 6 && r.high > r.low + 12)
        // A 0.1-amplitude sine is -23 dBFS RMS.
        #expect(abs(r.db + 23) < 0.3)
        meter.reset()
        #expect(meter.reading == .silence)
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
