import SwiftUI

/// The pill styles as picture tiles: a wallpaper swatch with the real pill drawn on it, the name
/// under it, and an accent ring on the selected one. Each tile is a button so Space picks it, and Left and Right step through them.
struct AppearanceStylePicker: View {
    /// The skin in use. Glass shows as Classic with its switch on.
    let selection: PillSkinKind
    var readout: PillReadoutColour = .default
    var wallpaper: PreviewWallpaper = .dark
    let onSelect: (PillSkinKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow("Style")
            HStack(spacing: 12) {
                ForEach(PillSkinKind.pickerKinds, id: \.rawValue) { skin in
                    // The Classic tile draws whichever of Classic or Glass is in use.
                    let drawn = skin == .classic && selection == .glass ? PillSkinKind.glass : skin
                    AppearanceStyleTile(skin: skin, drawn: drawn, readout: readout, wallpaper: wallpaper, selected: skin == selection.pickerKind) { onSelect(skin) }
                }
            }
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .accessibilityElement(children: .contain).accessibilityLabel("Pill style")
            .accessibilityIdentifier("settings-pill-style")
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let all = PillSkinKind.pickerKinds
        guard let index = all.firstIndex(of: selection.pickerKind) else { return .ignored }
        let next = min(max(index + offset, 0), all.count - 1)
        if next != index { onSelect(all[next]) }
        return .handled
    }
}

private struct AppearanceStyleTile: View {
    @Environment(\.colorScheme) private var scheme
    let skin: PillSkinKind
    let drawn: PillSkinKind
    let readout: PillReadoutColour
    let wallpaper: PreviewWallpaper
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearanceStyleArt(skin: drawn, readout: readout, wallpaper: wallpaper)
                    .frame(maxWidth: .infinity).frame(height: AppearanceStyleArt.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(skin.title).font(DesignFont.sans(12.5, .medium)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DesignPalette.accent).accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            .overlay { if selected { RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.accent, lineWidth: 1.5) } }
            .shadow(color: DesignPalette.shadowColor(dark: scheme == .dark), radius: 0.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skin.title) pill style")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-pill-style-" + skin.rawValue)
    }
}

/// The real pill for a tile: the same still `SettingsPillImage` draws for the preview, in the recording state with a level, trimmed
/// to the pill itself so it can be scaled to fit the tile. Static, never animated. A Glass pill shows the tint the offscreen
/// renderer draws in the material's place; the live preview above it has the real material.
@MainActor enum PillTileImage {
    private static var cache: [String: NSImage] = [:]

    static func image(skin: PillSkinKind, readout: PillReadoutColour, wallpaper: PreviewWallpaper) -> NSImage? {
        let key = "\(skin.rawValue)-\(readout.rawValue)-\(wallpaper.rawValue)"
        if let cached = cache[key] { return cached }
        guard let full = SettingsPillImage.make(skin: skin, size: .standard, readout: readout, wallpaper: wallpaper),
              let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil), let box = opaqueBounds(cg),
              let part = cg.cropping(to: box) else { return nil }
        let image = NSImage(cgImage: part, size: NSSize(width: CGFloat(part.width) / 2, height: CGFloat(part.height) / 2))
        cache[key] = image
        return image
    }

    /// The pixels holding anything drawn, with a pixel of margin.
    static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The context's rows run bottom-up, CGImage cropping is top-down.
        let top = height - 1 - maxY
        return CGRect(x: max(0, minX - 1), y: max(0, top - 1), width: min(width, maxX + 2) - max(0, minX - 1),
                      height: min(height, height - 1 - minY + 2) - max(0, top - 1))
    }
}

/// The pill for each style on the swatch the preview is showing, so the tile follows Light and Dark.
private struct AppearanceStyleArt: View {
    let skin: PillSkinKind
    let readout: PillReadoutColour
    let wallpaper: PreviewWallpaper

    static let height: CGFloat = 70

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let swatch = PreviewSwatch.image(wallpaper, size: proxy.size) {
                    Image(decorative: swatch, scale: 2).resizable().frame(width: proxy.size.width, height: proxy.size.height)
                }
                if let image = PillTileImage.image(skin: skin, readout: readout, wallpaper: wallpaper) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: min(image.size.width, proxy.size.width - 20), maxHeight: min(image.size.height, proxy.size.height - 16))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
