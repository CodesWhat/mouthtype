import AppKit
import Foundation
import MouthtypeCore

/// `--capture-selftest <seconds>`: record once after launch, log what came back, quit. A doctor command for the mic path.
enum CaptureSelfTest {
    static let flag = "--capture-selftest"

    static func seconds(in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), let seconds = Double(arguments[index + 1]), seconds > 0, seconds <= 60 else {
            return 2
        }
        return seconds
    }

    static func run(capture: AudioCapture, seconds: Double) async {
        do {
            try await capture.start(keyDownAtNanos: HostClock.now())
            var maxLevel: Float = 0
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                maxLevel = max(maxLevel, capture.level)
                try await Task.sleep(for: .milliseconds(16))
            }
            let audio = try await capture.stop()

            let features = AudioFeatures.compute(samples: audio.samples, sampleRate: Int(audio.sampleRate))
            let trimmed = SilenceTrimmer.trim(audio.samples)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mouthtype-selftest-\(UUID().uuidString)", isDirectory: true)
            let entry = try AudioArchive(supportDirectory: directory).write(samples: audio.samples, id: "selftest")

            func f(_ value: Double?, _ digits: Int = 0) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "none" }
            let line = "selftest device=\(audio.deviceName ?? "unknown") transport=\(audio.deviceTransport)"
                + " firstSampleMs=\(f(audio.firstSampleMs)) firstNonzeroMs=\(f(audio.firstNonzeroMs))"
                + " captureStartMs=\(f(audio.captureStartMs)) audioMs=\(f(audio.audioMs))"
                + " rmsDb=\(f(features.rmsDb, 1)) peakDb=\(f(features.peakDb, 1)) noiseFloorDb=\(f(features.noiseFloorDb, 1))"
                + " voicedMs=\(f(features.voicedMs)) trimmedMs=\(f(Double(trimmed.samples.count) * 1000 / audio.sampleRate))"
                + " headTrimmedMs=\(f(trimmed.headTrimmedMs)) levelMax=\(f(Double(maxLevel), 2)) wav=\(entry.url.path)"
            Log.capture.info("\(line, privacy: .public)")
        } catch {
            await capture.cancel()
            Log.capture.error("selftest failed: \(String(describing: error), privacy: .public)")
        }
    }
}
