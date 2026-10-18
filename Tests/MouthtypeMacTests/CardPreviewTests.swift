import AppKit
import Testing
@testable import MouthtypeMac

/// Writes each skin's delivery card at each size and appearance to PNG files when `MOUTHTYPE_CARD_PREVIEWS` names a
/// directory: a paste-failed card with its transcript, a question, the Undo countdown, and for Matrix and Minimal the
/// grown pill. Everything renders offscreen. The real glass material doesn't, so Glass shows a flat tint in its place,
/// which approximates the material and is not it.
@MainActor
@Suite struct CardPreviewTests {
    private static let backing: CGFloat = 2

    private enum Scene: String, CaseIterable {
        case failed, question, undo

        var card: DeliveryCard {
            switch self {
            case .failed: .pasteFailed("Send the mockups to Sean before Friday and copy the design channel.")
            case .question: .rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean"))
            case .undo: .cancelled()
            }
        }
    }

    private enum Look: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
        var backdrop: GlassPillPolicy.Backdrop { self == .light ? .init(luminance: 0.85, spread: 0.03) : .init(luminance: 0.12, spread: 0.03) }
        var colors: [CGColor] {
            self == .light
                ? [NSColor(hex: 0xEEF1F5).cgColor, NSColor(hex: 0xC9D2E0).cgColor]
                : [NSColor(hex: 0x3B4A6B).cgColor, NSColor(hex: 0x1D2436).cgColor]
        }
    }

    private func cardImage(_ view: DeliveryCardView, state: CardViewState, size: CGSize, look: Look) -> CGImage? {
        view.appearance = NSAppearance(named: look.appearance)
        view.render(state, typography: Typography.current())
        view.setFrameSize(size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = view.appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }

    private func canvas(_ size: CGSize, look: Look) throws -> CGContext {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width * Self.backing), height: Int(size.height * Self.backing), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.backing, y: Self.backing)
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: look.colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        return context
    }

    /// A card in its own panel (Classic, Hi-Fi, Glass) with the pill under it that says the detail line.
    private func separate(_ kind: PillSkinKind, scale: PillScale, scene: Scene, look: Look, environment: GlassPillEnvironment) throws -> CGImage {
        let k = scale.factor
        let card = scene.card
        let view = DeliveryCardView(frame: .zero, environment: environment)
        view.configure(style: kind.cardStyle, scale: scale, embedded: false)
        view.appearance = NSAppearance(named: look.appearance)
        view.render(CardViewState(card: card), typography: Typography.current())
        view.refreshBackdrop()
        let size = view.render(CardViewState(card: card), typography: Typography.current())
        let pillZone = PillGeometry.verticalMargin + kind.pillHeight * k + CardLayout.pillGap * k
        let canvasSize = CGSize(width: size.width + 24, height: pillZone + size.height - CardLayout.shadowMargin * k + 8)
        let context = try canvas(canvasSize, look: look)
        let origin = CGPoint(x: (canvasSize.width - size.width) / 2, y: pillZone - CardLayout.shadowMargin * k)
        if view.showsMaterial {
            let face = CGRect(origin: CGPoint(x: origin.x + CardLayout.shadowMargin * k, y: origin.y + CardLayout.shadowMargin * k), size: view.faceSize)
            let radius = CardLayout.cornerRadius * k
            context.saveGState()
            context.addPath(CGPath(roundedRect: face, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            if case .glass(.clear) = view.glassDecision {
                context.setFillColor(NSColor.white.withAlphaComponent(0.36).cgColor)
            } else {
                context.setFillColor(NSColor(srgbRed: 34 / 255, green: 34 / 255, blue: 40 / 255, alpha: 0.45).cgColor)
            }
            context.fill(face)
            context.restoreGState()
        }
        if let image = cardImage(view, state: CardViewState(card: card), size: size, look: look) {
            context.draw(image, in: CGRect(origin: origin, size: size))
        }
        if let message = card.pillMessage {
            let pill: any PillSkinView
            if kind == .glass {
                pill = GlassPillView(frame: NSRect(origin: .zero, size: canvasSize), size: scale, environment: environment)
            } else {
                pill = try PillSkinFactory.make(kind, frame: NSRect(origin: .zero, size: canvasSize), scale: scale)
            }
            pill.appear(reduceMotion: true)
            pill.showMessage(message, overRecording: false)
            pill.renderOffscreen(in: context)
        }
        return try #require(context.makeImage())
    }

    /// The pill grown into its card, with the readout row at the bottom.
    private func grown(_ kind: PillSkinKind, scale: PillScale, scene: Scene, look: Look) throws -> CGImage {
        let k = scale.factor
        let card = scene.card
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: kind.cardStyle, scale: scale, embedded: true)
        view.appearance = NSAppearance(named: look.appearance)
        view.render(CardViewState(card: card), typography: Typography.current())
        let face = view.faceSize
        let readout = try #require(view.readout)
        let canvasSize = CGSize(width: face.width + 48 * k, height: PillGeometry.verticalMargin + face.height + 30 * k + 24 * k)
        let skin = try #require(try PillSkinFactory.make(kind, frame: NSRect(origin: .zero, size: canvasSize), scale: scale) as? SquirclePillView)
        skin.appearance = NSAppearance(named: look.appearance)
        skin.reduceMotionOverride = true
        skin.appear(reduceMotion: true)
        skin.growCard(width: face.width, height: face.height, readout: readout, showReadout: true)
        let context = try canvas(canvasSize, look: look)
        skin.renderOffscreen(in: context)
        let frame = try #require(skin.cardFrame)
        if let image = cardImage(view, state: CardViewState(card: card), size: face, look: look) {
            context.draw(image, in: frame)
        }
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to directory: URL, name: String) throws {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func everySkinCardRendersAndOptionallyWritesPNGs() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_CARD_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for scale in [PillScale.standard, .large] {
            let size = scale == .large ? "large" : "standard"
            for scene in Scene.allCases {
                for look in Look.allCases {
                    for kind in [PillSkinKind.classic, .hifi, .glass, .matrix, .minimal] {
                        let image: CGImage
                        if kind.cardStyle.mergesIntoPill {
                            image = try grown(kind, scale: scale, scene: scene, look: look)
                        } else {
                            let environment = GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { false }, backdrop: { _ in look.backdrop })
                            image = try separate(kind, scale: scale, scene: scene, look: look, environment: environment)
                        }
                        #expect(image.width > 0 && image.height > 0)
                        if let directory { try write(image, to: directory, name: "\(kind.rawValue)-\(size)-\(scene.rawValue)-\(look.rawValue)") }
                    }
                    let solid = GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { true }, backdrop: { _ in nil })
                    let image = try separate(.glass, scale: scale, scene: scene, look: look, environment: solid)
                    if let directory { try write(image, to: directory, name: "glass-solid-\(size)-\(scene.rawValue)-\(look.rawValue)") }
                }
            }
        }
    }
}
