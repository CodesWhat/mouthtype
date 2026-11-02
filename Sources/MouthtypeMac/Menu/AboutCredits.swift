import AppKit

/// The credits shown when About is opened with Option held. The attributions are the ones in `THIRD_PARTY_NOTICES.md`: the
/// name, who made it and the licence. Plain text for VoiceOver, nothing persisted, nothing read from the app.
enum AboutCredits {
    struct Entry: Equatable {
        let name: String
        let role: String
        let attribution: String
    }

    static let entries: [Entry] = [
        Entry(
            name: "Instrument Serif", role: "The headline typeface",
            attribution: "Copyright 2022 The Instrument Serif Project Authors. SIL Open Font License 1.1."),
        Entry(
            name: "Parakeet TDT 0.6B v3", role: "Hears you",
            attribution: "NVIDIA, with the Core ML conversion by FluidInference. CC BY 4.0."),
        Entry(
            name: "FluidAudio", role: "Runs Parakeet on this Mac",
            attribution: "FluidInference. Apache License 2.0."),
    ]

    static let signoff = "That's everyone. Go say something."

    /// The lines in reading order, for tests.
    static var plainText: String {
        (entries.map { "\($0.name). \($0.role). \($0.attribution)" } + [signoff]).joined(separator: "\n")
    }

    static func attributed(font: NSFont = .systemFont(ofSize: 11)) -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let result = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor) {
            result.append(
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centered]))
        }
        for entry in entries {
            add("\(entry.name)\n", .boldSystemFont(ofSize: font.pointSize), .labelColor)
            add("\(entry.role)\n", font, .secondaryLabelColor)
            add("\(entry.attribution)\n\n", font, .secondaryLabelColor)
        }
        add(signoff, .systemFont(ofSize: font.pointSize, weight: .medium), .labelColor)
        return result
    }
}
