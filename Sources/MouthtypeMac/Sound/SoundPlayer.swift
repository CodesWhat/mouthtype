import AppKit

@MainActor
protocol SoundPlayer: AnyObject {
    func playStart()
    func playStop()
    func playError()
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

/// macOS system sounds at a low volume, loaded once at launch so the first cue plays without a load delay.
@MainActor
final class SystemSoundPlayer: SoundPlayer {
    static let startName = "Tink"
    static let stopName = "Pop"
    static let errorName = "Basso"
    static let volume: Float = 0.3

    private let defaults: UserDefaults
    private let start: NSSound?
    private let stop: NSSound?
    private let error: NSSound?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load(_ name: String) -> NSSound? {
            let sound = NSSound(named: name)
            sound?.volume = Self.volume
            if sound == nil { Log.app.error("system sound \(name, privacy: .public) not found") }
            return sound
        }
        start = load(Self.startName)
        stop = load(Self.stopName)
        error = load(Self.errorName)
    }

    var loadedAll: Bool { start != nil && stop != nil && error != nil }

    func playStart() { play(start) }
    func playStop() { play(stop) }
    func playError() { play(error) }

    private func play(_ sound: NSSound?) {
        guard SoundPreference.isEnabled(defaults), let sound else { return }
        sound.stop()
        sound.play()
    }
}
