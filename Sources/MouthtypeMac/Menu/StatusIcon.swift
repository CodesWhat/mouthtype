import AppKit

/// What the menu bar icon shows.
enum StatusIcon: CaseIterable {
    case idle, recording, processing, unavailable

    var glyphName: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .unavailable: "unavailable"
        }
    }

    /// The lips glyph, 16 x 15 pt with a 1x and a 2x representation. Always a template, so it follows the
    /// menu bar appearance. Recording shows the middle frame here; see `glyphFile(level:reduceMotion:)`.
    var image: NSImage? { Self.loadImage(named: glyphFile(level: 0.5, reduceMotion: true)) }

    /// The three recording frames, closed to wide open.
    static let recordingFiles = ["recording0", "recording1", "recording2"]

    /// Below `lowThreshold` the mouth is barely open, from `highThreshold` up it is wide open. The level is the
    /// pill's own smoothed meter value, 0...1.
    static let lowThreshold: Float = 0.25
    static let highThreshold: Float = 0.6

    /// Which recording frame a level shows. Reduce Motion pins the middle frame.
    static func recordingFrame(level: Float, reduceMotion: Bool) -> Int {
        if reduceMotion { return 1 }
        let level = level.isFinite ? level : 0
        if level >= highThreshold { return 2 }
        return level >= lowThreshold ? 1 : 0
    }

    /// The glyph file for this state. Only recording looks at the level.
    func glyphFile(level: Float, reduceMotion: Bool) -> String {
        guard self == .recording else { return glyphName }
        return Self.recordingFiles[Self.recordingFrame(level: level, reduceMotion: reduceMotion)]
    }

    static let glyphDirectory = "MenuBar"
    static let pointSize = NSSize(width: 16, height: 15)

    static func loadImage(named name: String, bundle: Bundle = .module) -> NSImage? {
        let image = NSImage(size: pointSize)
        for suffix in ["", "@2x"] {
            guard let url = bundle.url(forResource: "glyph-\(name)\(suffix)", withExtension: "png", subdirectory: glyphDirectory),
                  let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { return nil }
            rep.size = pointSize
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mouthtype"
        return image
    }

    /// `--status-icon <state>`: pins the icon to one state, for screenshots.
    static func pinned(in arguments: [String]) -> StatusIcon? {
        guard let index = arguments.firstIndex(of: "--status-icon"), arguments.indices.contains(index + 1) else { return nil }
        return allCases.first { $0.glyphName == arguments[index + 1] }
    }

    /// An engine that failed, or missing microphone or Accessibility access, outranks the dictation phase.
    static func resolve(
        phase: DictationController.Phase, engineFailed: Bool, microphoneAllowed: Bool, accessibilityGranted: Bool
    ) -> StatusIcon {
        if engineFailed || !microphoneAllowed || !accessibilityGranted { return .unavailable }
        switch phase {
        case .idle: return .idle
        case .recording: return .recording
        case .processing: return .processing
        }
    }
}

/// Decides when the status item's image should change: at once on a state change, and for the level-driven
/// recording frames at most `maxFramesPerSecond` times a second, and only when the frame differs.
struct StatusGlyphGate {
    static let maxFramesPerSecond = 15.0

    private(set) var file: String?
    private var lastSwap: TimeInterval = -.infinity
    private var icon: StatusIcon?

    /// The file to show now, or nil to leave the status item alone. Nothing is committed unless `canShow` says the
    /// image for the wanted file is available, so a failed load is retried on the next update.
    mutating func next(
        icon: StatusIcon, level: Float, reduceMotion: Bool, now: TimeInterval, canShow: (String) -> Bool = { _ in true }
    ) -> String? {
        let wanted = icon.glyphFile(level: level, reduceMotion: reduceMotion)
        guard wanted != file else { self.icon = icon; return nil }
        if icon == self.icon, icon == .recording, now - lastSwap < 1 / Self.maxFramesPerSecond { return nil }
        guard canShow(wanted) else { return nil }
        file = wanted
        lastSwap = now
        self.icon = icon
        return wanted
    }
}
