import AppKit
import Testing
@testable import MouthtypeMac

/// Writes the pill at each skin and size to PNG files when `MOUTHTYPE_PILL_SIZE_PREVIEWS` names a directory, through the
/// same offscreen layer rendering the settings pill preview uses. Without it the test only checks that rendering works.
@MainActor
@Suite struct PillSizePreviewTests {
    private static let fractions: [Float] = [0.2, 0.4, 0.6, 0.8, 0.5, 0.35, 0.65, 0.3, 0.2, 0.1]
    private static let backing: CGFloat = 2

    private enum Scene: String, CaseIterable {
        case recording, locked, message, messageDetail, cardWithPill
    }

    private func skinView(_ kind: PillSkinKind, scale: PillScale, size: CGSize) throws -> any PillSkinView {
        let frame = NSRect(origin: .zero, size: size)
        switch kind {
        case .classic: return ClassicPillView(frame: frame, size: scale)
        case .hifi: return HiFiPillView(frame: frame, assets: try PillAssets.loadHiFi(), size: scale)
        }
    }

    private func cardImage(_ card: DeliveryCard) -> (image: CGImage, size: CGSize)? {
        let view = DeliveryCardView(frame: .zero)
        let size = view.render(CardViewState(card: card), typography: Typography.current())
        view.setFrameSize(size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage.map { ($0, size) }
    }

    private func render(_ kind: PillSkinKind, scale: PillScale, scene: Scene) throws -> CGImage {
        let panel = PillGeometry.panelSize(for: scale)
        let canvas = CGSize(width: panel.width, height: scene == .cardWithPill ? panel.height + 200 : panel.height)
        let view = try skinView(kind, scale: scale, size: canvas)
        view.appear(reduceMotion: true)
        let card = DeliveryCard.pasteFailed("Send the revised notes to Priya before the meeting.")
        switch scene {
        case .recording:
            view.showRecording(locked: false)
            view.showFractions(Self.fractions)
        case .locked:
            view.showRecording(locked: true)
            view.showFractions(Self.fractions)
        case .message:
            view.showMessage(PillMessage("Cancelled"), overRecording: false)
        case .messageDetail:
            view.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        case .cardWithPill:
            view.showMessage(try #require(card.pillMessage), overRecording: false)
        }

        let pixels = (width: Int(canvas.width * Self.backing), height: Int(canvas.height * Self.backing))
        let context = try #require(CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.backing, y: Self.backing)
        context.setFillColor(NSColor(hex: 0x8E96A3).cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))
        if scene == .cardWithPill, let (image, size) = cardImage(card) {
            let pillHeight = (kind == .hifi ? HiFiPillView.artSize.height : ClassicPillLayout.height) * scale.factor
            let origin = CGPoint(
                x: ((canvas.width - size.width) / 2).rounded(.down),
                y: PillGeometry.verticalMargin + pillHeight + CardLayout.pillGap - CardLayout.shadowMargin
            )
            context.draw(image, in: CGRect(origin: origin, size: size))
        }
        view.layer?.render(in: context)
        return try #require(context.makeImage())
    }

    @Test func everySkinSizeAndSceneRendersAndOptionallyWritesPNGs() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_PILL_SIZE_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for kind in PillSkinKind.allCases {
            for scale in [PillScale.standard, .large] {
                for scene in Scene.allCases {
                    let image = try render(kind, scale: scale, scene: scene)
                    #expect(image.width > 0 && image.height > 0)
                    guard let directory else { continue }
                    let name = "\(kind.rawValue)-\(scale == .large ? "large" : "standard")-\(scene.rawValue).png"
                    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }
}
