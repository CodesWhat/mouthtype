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

    /// The smiley glyph, 16 x 15 pt with a 1x and a 2x representation. Always a template, so it follows the
    /// menu bar appearance.
    var image: NSImage? { Self.loadImage(named: glyphName) }

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
