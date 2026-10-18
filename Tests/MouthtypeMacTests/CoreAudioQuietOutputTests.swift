import CoreAudio
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHTYPE_NATIVE_AUDIO_TESTS"] == "1"))
struct CoreAudioQuietOutputTests {
    @Test func delayedOwnMuteNotificationsStillAllowRestoration() async throws {
        let output = CoreAudioQuietOutput()
        let device = try output.currentOutput()
        try #require(try !output.isMuted(device), "Native audio checks require an initially unmuted output")
        defer { try? output.setMuted(false, output: device) }

        for _ in 0..<10 {
            let quiet = RecordingAudioQuiet(output: output, enabled: { true })
            quiet.begin()
            try await Task.sleep(for: .milliseconds(150))
            #expect(try output.isMuted(device))
            quiet.end()
            #expect(try !output.isMuted(device))
            try output.setMuted(false, output: device)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func subsequentUnmuteAndRemutePreserveTheNewMute() async throws {
        let output = CoreAudioQuietOutput()
        let device = try output.currentOutput()
        try #require(try !output.isMuted(device), "Native audio checks require an initially unmuted output")
        defer { try? output.setMuted(false, output: device) }
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin()
        try await Task.sleep(for: .milliseconds(150))
        try output.setMuted(false, output: device)
        try await Task.sleep(for: .milliseconds(150))
        try output.setMuted(true, output: device)
        try await Task.sleep(for: .milliseconds(150))
        quiet.end()
        #expect(try output.isMuted(device))
    }

    @Test func volumeAdjustmentWhileMutedRelinquishesRestoration() async throws {
        let output = CoreAudioQuietOutput()
        let device = try output.currentOutput()
        try #require(try !output.isMuted(device), "Native audio checks require an initially unmuted output")
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try #require(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &volume) == noErr)
        let original = volume
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        defer {
            quiet.end()
            volume = original
            _ = AudioObjectSetPropertyData(device.id, &address, 0, nil, size, &volume)
            try? output.setMuted(false, output: device)
        }
        quiet.begin()
        try await Task.sleep(for: .milliseconds(150))
        volume = original < 0.95 ? original + 0.01 : original - 0.01
        try #require(AudioObjectSetPropertyData(device.id, &address, 0, nil, size, &volume) == noErr)
        try await Task.sleep(for: .milliseconds(150))
        quiet.end()
        #expect(try output.isMuted(device))
    }
}
