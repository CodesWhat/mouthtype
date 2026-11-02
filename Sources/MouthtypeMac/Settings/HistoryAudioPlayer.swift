import Foundation
import AVFAudio

@MainActor protocol HistoryAudioPlaying: AnyObject {
    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws
    func stop()
}

@MainActor final class HistoryAudioPlayer: NSObject, HistoryAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: (@MainActor (Bool) -> Void)?

    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws {
        stop()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        self.player = player
        self.finished = finished
        guard player.play() else {
            stop()
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        finished = nil
    }

    isolated deinit { player?.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.complete(identity, success: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.complete(identity, success: false) }
    }

    private func complete(_ identity: ObjectIdentifier, success: Bool) {
        guard let player, ObjectIdentifier(player) == identity else { return }
        let completion = finished
        stop()
        completion?(success)
    }
}
