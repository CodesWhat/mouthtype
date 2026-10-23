import AppKit
import AVFAudio

@MainActor
protocol SoundPlayer: AnyObject {
    var startCueDuration: TimeInterval { get }
    var isStartCuePlaying: Bool { get }
    func playStart()
    func playStop()
    func playLock()
    func playError()
}

extension SoundPlayer {
    var startCueDuration: TimeInterval { 0 }
    var isStartCuePlaying: Bool { false }
}

enum SoundPreference {
    static let key = "soundsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// The Click cues are decoded and prepared at launch, before the first key press.
@MainActor
final class ClickSoundPlayer: SoundPlayer {
    static let startName = "start"
    static let stopName = "stop"
    static let lockName = "lock"
    static let errorName = "error"
    static let volume: Float = 0.5

    private let defaults: UserDefaults
    private let start: AVAudioPlayer?
    private let stop: AVAudioPlayer?
    private let lock: AVAudioPlayer?
    private let error: AVAudioPlayer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load(_ name: String) -> AVAudioPlayer? {
            do {
                guard let url = Self.cueURL(name) else { throw CocoaError(.fileNoSuchFile) }
                let sound = try AVAudioPlayer(contentsOf: url)
                sound.volume = Self.volume
                sound.numberOfLoops = 0
                guard sound.prepareToPlay() else { throw CocoaError(.fileReadUnknown) }
                return sound
            } catch {
                Log.app.error("Click cue \(name, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        start = load(Self.startName)
        stop = load(Self.stopName)
        lock = load(Self.lockName)
        error = load(Self.errorName)
    }

    var loadedAll: Bool { start != nil && stop != nil && lock != nil && error != nil }

    var startCueDuration: TimeInterval { SoundPreference.isEnabled(defaults) ? (start?.duration ?? 0) : 0 }
    var isStartCuePlaying: Bool { start?.isPlaying == true }

    static func cueURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds/Click")
    }

    func playStart() { play(start, name: Self.startName) }
    func playStop() { play(stop, name: Self.stopName) }
    func playLock() { play(lock, name: Self.lockName) }
    func playError() { play(error, name: Self.errorName) }

    private func play(_ sound: AVAudioPlayer?, name: String) {
        guard SoundPreference.isEnabled(defaults), let sound else { return }
        sound.stop()
        sound.currentTime = 0
        if sound.play() { Log.app.info("Click cue \(name, privacy: .public)") } else { Log.app.error("Click cue \(name, privacy: .public) could not play") }
    }
}
