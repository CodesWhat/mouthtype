import Foundation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class HistoryAudioSpy: HistoryAudioPlaying {
    var played: [URL] = []
    var stops = 0
    var fails = false
    var completions: [@MainActor (Bool) -> Void] = []
    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws {
        if fails { throw CocoaError(.fileReadCorruptFile) }
        played.append(url)
        completions.append(finished)
    }
    func stop() { stops += 1 }
}

@MainActor @Suite struct HistoryPlaybackTests {
    @Test func playerRejectsRemoteAndMissingFilesWithoutStartingAudio() {
        let player = HistoryAudioPlayer()
        #expect(throws: (any Error).self) {
            try player.play(URL(string: "https://example.invalid/recording.wav")!) { _ in }
        }
        #expect(throws: (any Error).self) {
            try player.play(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")) { _ in }
        }
        player.stop()
    }

    private func take(_ id: String) -> HomeTake {
        HomeTake(
            id: id, startedAt: .now, text: "Sample", appName: nil,
            recoverable: RecoverableDictation(
                id: id, startedAt: .now,
                audioURL: URL(fileURLWithPath: "/tmp/\(id).wav"), seconds: 4, isPartial: false))
    }

    @Test func explicitPlaybackSwitchesStopsAndIgnoresOldCompletion() {
        let player = HistoryAudioSpy()
        let model = HomeLogModel(observing: false)
        model.audioPlayer = player
        model.togglePlayback(take("a"))
        #expect(model.playingID == "a")
        #expect(player.played.map(\.lastPathComponent) == ["a.wav"])
        model.togglePlayback(take("b"))
        #expect(model.playingID == "b")
        #expect(player.played.map(\.lastPathComponent) == ["a.wav", "b.wav"])
        player.completions.first?(true)
        #expect(model.playingID == "b")
        model.togglePlayback(take("b"))
        #expect(model.playingID == nil)
        #expect(player.stops >= 2)
    }

    @Test func completionAndFailuresClearPlayingState() {
        let player = HistoryAudioSpy()
        let model = HomeLogModel(observing: false)
        model.audioPlayer = player
        model.togglePlayback(take("a"))
        player.completions.last?(true)
        #expect(model.playingID == nil)
        #expect(model.playbackError == nil)
        player.fails = true
        model.togglePlayback(take("b"))
        #expect(model.playingID == nil)
        #expect(model.playbackError != nil)
        player.fails = false
        model.togglePlayback(take("c"))
        #expect(model.playbackError == nil)
        player.completions.last?(false)
        #expect(model.playingID == nil)
        #expect(model.playbackError != nil)
    }

    @Test func queryCaptureAndPageCloseStopPlaybackAndUnavailableAudioCannotStart() {
        let player = HistoryAudioSpy()
        let gate = RecoverGate()
        let model = HomeLogModel(canRecover: { gate.open })
        model.canPlay = { gate.open }
        model.audioPlayer = player
        model.togglePlayback(take("a"))
        model.query = "other"
        #expect(model.playingID == nil)
        model.togglePlayback(take("b"))
        gate.open = false
        model.refreshRecoverability()
        #expect(model.playingID == nil)
        model.togglePlayback(take("c"))
        #expect(player.played.count == 2)
        gate.open = true
        model.refreshRecoverability()
        model.togglePlayback(take("d"))
        model.deactivate()
        #expect(model.playingID == nil)
        var noAudio = take("e")
        noAudio.recoverable = nil
        model.togglePlayback(noAudio)
        #expect(player.played.count == 3)
    }

    @Test func removingRetainedAudioStopsPlayback() {
        let model = HomeLogModel(observing: false)
        let player = HistoryAudioSpy()
        model.audioPlayer = player
        let row = take("a")
        model.attach([row.recoverable!])
        model.togglePlayback(row)
        model.attach([])
        #expect(model.playingID == nil)
        #expect(player.stops >= 1)
    }
}
