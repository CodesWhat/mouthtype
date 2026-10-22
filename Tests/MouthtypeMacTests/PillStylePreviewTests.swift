import AppKit
import Testing
@testable import MouthtypeMac

/// Writes the Glass, Matrix and Minimal pills at each size, state and appearance to PNG files when
/// `MOUTHTYPE_PILL_STYLE_PREVIEWS` names a directory. The real glass material doesn't render offscreen, so Glass is
/// written as its solid fallback and as the glass body's tint and specular edge over a light and a dark wallpaper
/// swatch, which approximates the material and is not it.
@MainActor
@Suite struct PillStylePreviewTests {
    private static let fractions: [Float] = [0.1, 0.25, 0.45, 0.7, 0.95, 0.6, 0.85, 0.5, 0.3, 0.05]
    private static let backing: CGFloat = 2

    private enum Scene: String, CaseIterable {
        case recording, locked, processing, message, messageDetail, error
    }

    private enum Backdrop: String {
        case light, dark

        var colors: (CGColor, CGColor) {
            switch self {
            case .light: (NSColor(hex: 0xEEF1F5).cgColor, NSColor(hex: 0xC9D2E0).cgColor)
            case .dark: (NSColor(hex: 0x3B4A6B).cgColor, NSColor(hex: 0x1D2436).cgColor)
            }
        }
    }

    private func glassEnvironment(reduceTransparency: Bool, backdrop: GlassPillPolicy.Backdrop?) -> GlassPillEnvironment {
        GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { reduceTransparency }, backdrop: { _ in backdrop })
    }

    private func configure(_ view: any PillSkinView, scene: Scene, time: TimeInterval = 0.31) {
        view.appear(reduceMotion: true)
        switch scene {
        case .recording:
            view.showRecording(locked: false)
            view.showFractions(Self.fractions)
        case .locked:
            view.showRecording(locked: true)
            view.showFractions(Self.fractions)
            view.setElapsed(4)
        case .processing:
            view.beginProcessing()
            view.updateProcessing(time: time)
        case .message:
            view.showMessage(PillMessage("Pasted"), overRecording: false)
        case .messageDetail:
            view.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        case .error:
            view.showMessage(PillMessage("Paste failed", isError: true), overRecording: false)
        }
    }

    private func render(_ view: any PillSkinView, scale: PillScale, backdrop: Backdrop, fullHeight: Bool = false) throws -> CGImage {
        let canvas = PillGeometry.panelSize(for: scale)
        let width = min(canvas.width, 230 * scale.factor)
        let crop = CGRect(
            x: (canvas.width - width) / 2, y: 0, width: width, height: fullHeight ? canvas.height : min(canvas.height, 24 + 72 * scale.factor)
        )
        let pixels = (width: Int(crop.width * Self.backing), height: Int(crop.height * Self.backing))
        let context = try #require(
            CGContext(
                data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.scaleBy(x: Self.backing, y: Self.backing)
        context.translateBy(x: -crop.minX, y: 0)
        let (top, bottom) = backdrop.colors
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: crop.minX, y: crop.height), end: CGPoint(x: crop.maxX, y: 0), options: [])
        view.renderOffscreen(in: context)
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to directory: URL, name: String) throws {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func sizeName(_ scale: PillScale) -> String { scale == .large ? "large" : "standard" }

    @Test func everyStyleSizeStateAndAppearanceRendersAndOptionallyWritesPNGs() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_PILL_STYLE_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for scale in [PillScale.standard, .large] {
            let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
            for scene in Scene.allCases {
                for kind in [PillSkinKind.matrix, .minimal] {
                    for (appearance, backdrop) in [(NSAppearance.Name.aqua, Backdrop.light), (.darkAqua, .dark)] {
                        let view = try #require(try PillSkinFactory.make(kind, frame: frame, scale: scale) as? SquirclePillView)
                        view.appearance = NSAppearance(named: appearance)
                        view.reduceMotionOverride = true
                        configure(view, scene: scene)
                        let image = try render(view, scale: scale, backdrop: backdrop)
                        #expect(image.width > 0)
                        if let directory { try write(image, to: directory, name: "\(kind.rawValue)-\(sizeName(scale))-\(scene.rawValue)-\(backdrop.rawValue)") }
                    }
                }
                let cases: [(String, GlassPillEnvironment, Backdrop)] = [
                    ("solid-light", glassEnvironment(reduceTransparency: true, backdrop: nil), .light),
                    ("solid-dark", glassEnvironment(reduceTransparency: true, backdrop: nil), .dark),
                    ("over-light", glassEnvironment(reduceTransparency: false, backdrop: .init(luminance: 0.85, spread: 0.03)), .light),
                    ("over-dark", glassEnvironment(reduceTransparency: false, backdrop: .init(luminance: 0.12, spread: 0.03)), .dark),
                ]
                for (name, environment, backdrop) in cases {
                    let view = GlassPillView(frame: frame, size: scale, environment: environment)
                    configure(view, scene: scene)
                    let image = try render(view, scale: scale, backdrop: backdrop)
                    #expect(image.width > 0)
                    if let directory { try write(image, to: directory, name: "glass-\(name)-\(sizeName(scale))-\(scene.rawValue)") }
                }
            }
        }
    }

    /// A 300 character error in Matrix and Minimal at both sizes, at the start and the end of its scroll.
    @Test func aLongMessageRendersAtTheStartAndEndOfItsScroll() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_PILL_STYLE_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for scale in [PillScale.standard, .large] {
            let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
            for kind in [PillSkinKind.matrix, .minimal] {
                for (appearance, backdrop) in [(NSAppearance.Name.aqua, Backdrop.light), (.darkAqua, .dark)] {
                    let view = try #require(try PillSkinFactory.make(kind, frame: frame, scale: scale) as? SquirclePillView)
                    view.appearance = NSAppearance(named: appearance)
                    view.reduceMotionOverride = true
                    view.appear(reduceMotion: true)
                    view.showMessage(PillMessage("Transcription failed", detail: SquirclePillViewTests.longError, isError: true), overRecording: false)
                    for (name, offset) in [("start", 0), ("end", -view.messageScrollDistance)] {
                        view.setMessageOffset(offset)
                        let image = try render(view, scale: scale, backdrop: backdrop, fullHeight: true)
                        #expect(image.width > 0)
                        if let directory {
                            try write(image, to: directory, name: "long-message-\(kind.rawValue)-\(sizeName(scale))-\(backdrop.rawValue)-\(name)")
                        }
                    }
                }
            }
        }
    }
}
