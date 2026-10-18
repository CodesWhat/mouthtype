import AppKit
import ImageIO
import Testing
@testable import MouthtypeMac

/// Writes the Hi-Fi delivery card at Standard and Large to PNG files when `MOUTHTYPE_HIFI_CARD_PREVIEWS` names a
/// directory: each scene with the Hi-Fi pill under it on the dark desktop backdrop, each readout colour once, and when
/// `MOUTHTYPE_HIFI_DECK_REFERENCE` names the Hi-Fi deck mock-up, a side-by-side with it at the mock-up's 3x.
@MainActor
@Suite struct HiFiCardPreviewTests {
    private enum Scene: String, CaseIterable {
        case failed, question, undo, error

        var card: DeliveryCard {
            switch self {
            case .failed: .pasteFailed("Send the mockups to Sean before Friday and copy the design channel on it.")
            case .question: .rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean"))
            case .undo: .cancelled()
            case .error: .notLanded("Remind me to reply to the SYP thread after the standup, then ship it after lunch.")
            }
        }
    }

    private func canvas(_ size: CGSize, backing: CGFloat) throws -> CGContext {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width * backing), height: Int(size.height * backing), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: backing, y: backing)
        let colors = [NSColor(hex: 0x3B4A6B).cgColor, NSColor(hex: 0x1D2436).cgColor]
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        return context
    }

    /// The card over the Hi-Fi pill, which says the card's detail line.
    private func composite(card: DeliveryCard, scale: PillScale, readout: PillReadoutColour, backing: CGFloat) throws -> CGImage {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let k = scale.factor
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: .hifi, scale: scale, embedded: false, readout: readout)
        view.appearance = NSAppearance(named: .darkAqua)
        let size = view.render(CardViewState(card: card), typography: Typography.current())
        let pillZone = PillGeometry.verticalMargin + PillSkinKind.hifi.pillHeight * k + CardLayout.pillGap * k
        let canvasSize = CGSize(width: size.width + 24, height: pillZone + size.height - CardLayout.shadowMargin * k + 8)
        let context = try canvas(canvasSize, backing: backing)
        let origin = CGPoint(x: (canvasSize.width - size.width) / 2, y: pillZone - CardLayout.shadowMargin * k)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = view.appearance
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * backing), pixelsHigh: Int(size.height * backing), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        context.interpolationQuality = .none
        if let image = bitmap.cgImage { context.draw(image, in: CGRect(origin: origin, size: size)) }
        let pill = try PillSkinFactory.make(.hifi, frame: NSRect(origin: .zero, size: canvasSize), scale: scale, readout: readout)
        pill.appear(reduceMotion: true)
        if let message = card.pillMessage { pill.showMessage(message, overRecording: false) } else { pill.showFractions([]) }
        pill.renderOffscreen(in: context)
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to directory: URL, name: String) throws {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func everySceneRendersAndOptionallyWritesPNGs() throws {
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_HIFI_CARD_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for scale in [PillScale.standard, .large] {
            let size = scale == .large ? "large" : "standard"
            for scene in Scene.allCases {
                let image = try composite(card: scene.card, scale: scale, readout: .amber, backing: 2)
                #expect(image.width > 0 && image.height > 0)
                if let directory { try write(image, to: directory, name: "\(size)-\(scene.rawValue)") }
            }
            for readout in PillReadoutColour.allCases {
                let image = try composite(card: Scene.failed.card, scale: scale, readout: readout, backing: 2)
                if let directory { try write(image, to: directory, name: "\(size)-readout-\(readout.rawValue)") }
            }
        }
        // Side by side with the mock-up, which is drawn at 3 pixels per art pixel: the card is rendered at that scale.
        guard let directory, let path = ProcessInfo.processInfo.environment["MOUTHTYPE_HIFI_DECK_REFERENCE"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let reference = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        for scene in [Scene.failed, .undo] {
            let card = try composite(card: scene.card, scale: .standard, readout: .amber, backing: 3)
            let size = CGSize(width: CGFloat(reference.width + card.width + 30), height: CGFloat(max(reference.height, card.height)))
            let context = try canvas(CGSize(width: size.width, height: size.height), backing: 1)
            context.interpolationQuality = .none
            context.draw(reference, in: CGRect(x: 0, y: size.height - CGFloat(reference.height), width: CGFloat(reference.width), height: CGFloat(reference.height)))
            context.draw(card, in: CGRect(x: CGFloat(reference.width) + 30, y: size.height - CGFloat(card.height), width: CGFloat(card.width), height: CGFloat(card.height)))
            try write(try #require(context.makeImage()), to: directory, name: "compare-deck-\(scene.rawValue)")
        }
    }
}
