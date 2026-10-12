import AVFoundation
import Foundation
import Testing
@testable import MouthtypeMac

/// `CGEvent.timestamp` is nanoseconds since boot, not `mach_absolute_time` ticks. These pin the one unit used
/// above the audio render callback: a press stamped "now" and audio 50 ms later must read as 50 ms.
@Suite struct TimestampUnitTests {
    @Test func hostClockNowIsNanosecondsSinceBoot() {
        let uptimeNanos = ProcessInfo.processInfo.systemUptime * 1_000_000_000
        #expect(abs(Double(HostClock.now()) - uptimeNanos) < 2_000_000_000)
    }

    @Test func firstSampleDelayIsMillisecondsFromAPressStampedInNanoseconds() throws {
        let capture = AudioCapture.self
        let buffer = CaptureBuffer()
        let converters = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let press = HostClock.now()
        buffer.reset(startedAt: press)
        let handler = capture.inputHandler(buffer: buffer, converters: converters, onLevel: nil)

        let pcm = try makePCM(sampleRate: 48_000, channels: 1, frames: 4_800)
        handler(pcm, press + 50_000_000, press + 60_000_000)

        let stats = buffer.currentStats
        let firstSampleMs = try #require(stats.firstSampleDelay) * 1000
        let firstSoundMs = try #require(stats.firstSoundDelay) * 1000
        #expect(abs(firstSampleMs - 50) < 1)
        #expect(firstSoundMs >= 50 && firstSoundMs < 52)
        #expect(stats.buffers == 1)
        #expect(try buffer.finish().count > 0)
    }

    @Test func coreAudioTicksAreConvertedAsTheyEnter() {
        let ticks = mach_absolute_time()
        let nanos = HostClock.nanoseconds(fromHostTime: ticks)
        #expect(abs(Double(nanos) - Double(HostClock.now())) < 1_000_000_000)
    }

    @Test func systemClockReportsATwoSecondHoldAsTwoThousandMs() {
        let clock = SystemDictationClock()
        let down = clock.nowNanos()
        #expect(clock.milliseconds(from: down, to: down + 2_000_000_000) == 2_000)
        #expect(clock.milliseconds(from: down + 5, to: down) == 0)
    }

    @Test func eventDateIsNotRescaledByTheTimebase() {
        let a = HotkeyService.date(nanos: 10_000_000_000)
        let b = HotkeyService.date(nanos: 12_000_000_000)
        #expect(abs(b.timeIntervalSince(a) - 2) < 1e-9)
    }

    @Test func pastPressDateLandsInThePast() {
        let clock = SystemDictationClock()
        let date = clock.date(atNanos: clock.nowNanos() - 2_000_000_000)
        let ago = Date().timeIntervalSince(date)
        #expect(ago > 1.9 && ago < 3)
    }
}
