import AppKit
import SwiftUI

/// The seven 16x16 pixel icons (Resources/Settings/Icons), bundled as 1x, 2x and 4x template PNGs. They are single-colour, so
/// `DesignIconView` tints them with the symbol colour. Every other glyph in the UI stays an SF Symbol line glyph on purpose.
enum DesignIcon: String, CaseIterable, Identifiable {
    case home, stats, dictionary, transforms, style, appearance, settings
    var id: String { rawValue }

    /// A 16x16 pt template image carrying all three scales, or nil when the bundle lacks the files.
    @MainActor var image: NSImage? { Self.cache[self] ?? load() }

    @MainActor private static var cache: [DesignIcon: NSImage] = [:]

    @MainActor private func load() -> NSImage? {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for suffix in ["", "@2x", "@4x"] {
            guard let url = Bundle.module.url(forResource: rawValue + suffix, withExtension: "png", subdirectory: "Settings/Icons"),
                  let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 16, height: 16)
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }
}

/// A pixel icon at its drawn 16 pt, tinted with the secondary ink unless told otherwise. Decorative: the row it sits in carries the label.
struct DesignIconView: View {
    let icon: DesignIcon
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = icon.image {
                Image(nsImage: image).renderingMode(.template).interpolation(.none).resizable()
            } else {
                Color.clear
            }
        }
        .foregroundStyle(DesignPalette.ink2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
