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

    /// The caret lips glyph, 16 pt with a 1x and a 2x representation. Always a template, so it follows the
    /// menu bar appearance.
    var image: NSImage? { Self.loadImage(named: glyphName) }

    static let glyphDirectory = "MenuBar"
    static let pointSize = NSSize(width: 16, height: 16)

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
