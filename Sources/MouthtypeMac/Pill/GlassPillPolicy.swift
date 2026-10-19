import AppKit
import ImageIO

/// When the Glass pill uses the system material and when it falls back to the solid Classic body, with no view in it.
enum GlassPillPolicy {
    enum Variant: Equatable, Sendable {
        /// Clear glass over light content, with dark ink.
        case clear
        /// Smoked glass over dark content, with the Classic light ink.
        case smoked
    }

    enum Fallback: Equatable, Sendable {
        case materialUnavailable, reduceTransparency
    }

    enum Decision: Equatable, Sendable {
        case glass(Variant)
        case solid(Fallback)

        var usesMaterial: Bool {
            if case .glass = self { return true }
            return false
        }
    }

    /// What lies behind the pill: relative luminance 0 (black) to 1 (white) averaged over the sampled area, and how
    /// much it varies (standard deviation of the same).
    struct Backdrop: Equatable, Sendable {
        var luminance: Double
        var spread: Double
    }

    /// At or above this the backdrop is light enough for clear glass with dark ink. Anything below it, mid-tone or busy
    /// included, gets smoked glass with the Classic light ink: the wallpaper never makes Glass fall back to solid.
    static let lightLimit = 0.62

    /// `backdrop` nil means the wallpaper couldn't be read. Smoked glass is the dark-safe choice then, because its tint
    /// carries the light ink on its own.
    static func decide(materialAvailable: Bool, reduceTransparency: Bool, backdrop: Backdrop?) -> Decision {
        guard materialAvailable else { return .solid(.materialUnavailable) }
        guard !reduceTransparency else { return .solid(.reduceTransparency) }
        guard let backdrop else { return .glass(.smoked) }
        return backdrop.luminance >= lightLimit ? .glass(.clear) : .glass(.smoked)
    }

    /// Relative luminance of an sRGB colour with 0...1 channels.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Mean and spread of the luminance over RGBA8 `pixels` (premultiplied alpha is fine, the wallpaper is opaque).
    static func analyze(rgba pixels: [UInt8]) -> Backdrop? {
        let count = pixels.count / 4
        guard count > 0 else { return nil }
        var values = [Double]()
        values.reserveCapacity(count)
        for i in 0..<count {
            values.append(luminance(
                red: Double(pixels[4 * i]) / 255, green: Double(pixels[4 * i + 1]) / 255, blue: Double(pixels[4 * i + 2]) / 255
            ))
        }
        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        return Backdrop(luminance: mean, spread: variance.squareRoot())
    }
}

/// Reads the desktop picture under the pill at thumbnail size, so it needs no screen recording permission. Windows over
/// the wallpaper are not seen. The decode is slow on a 5K or 6K picture, so it only ever runs off the main thread, see
/// `GlassBackdropCache`.
enum GlassBackdropSampler {
    private static let thumbnailPixels = 96
    private static let sampleSize = (width: 24, height: 8)

    nonisolated static func measure(url: URL, screenFrame: CGRect, region: CGRect) -> GlassPillPolicy.Backdrop? {
        guard let image = thumbnail(url: url, maxPixels: thumbnailPixels) else { return nil }
        let crop = cropRect(imageSize: CGSize(width: image.width, height: image.height), screenFrame: screenFrame, region: region)
        guard let part = image.cropping(to: crop) else { return nil }
        return backdrop(of: part)
    }

    /// Mean luminance and spread of `image`, sampled down to a small fixed grid. The one pixel path both the real pill
    /// and the Appearance preview's swatches go through.
    nonisolated static func backdrop(of image: CGImage) -> GlassPillPolicy.Backdrop? {
        let (w, h) = sampleSize
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GlassPillPolicy.analyze(rgba: pixels) : nil
    }

    /// The picture downsampled so its longest side is at most `maxPixels`, orientation applied. Slow on a large file, so
    /// only ever call it off the main thread.
    nonisolated static func thumbnail(url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The part of the wallpaper (in image pixels, top-left origin) behind `region`, with the picture scaled to fill
    /// the screen and centred, which is how the desktop shows most pictures.
    nonisolated static func cropRect(imageSize: CGSize, screenFrame: CGRect, region: CGRect) -> CGRect {
        let scale = max(screenFrame.width / imageSize.width, screenFrame.height / imageSize.height)
        let offsetX = (screenFrame.width - imageSize.width * scale) / 2
        let offsetY = (screenFrame.height - imageSize.height * scale) / 2
        // Screen y grows upward, image rows downward.
        let x = (region.minX - screenFrame.minX - offsetX) / scale
        let y = (screenFrame.maxY - region.maxY - offsetY) / scale
        let bounds = CGRect(origin: .zero, size: imageSize)
        let rect = CGRect(x: x, y: y, width: region.width / scale, height: region.height / scale).intersection(bounds)
        return rect.isNull || rect.width < 1 || rect.height < 1 ? bounds : rect.integral.intersection(bounds)
    }
}

/// What the sampler measured, per screen, so the pill never decodes a wallpaper on the hotkey path. A lookup that has no
/// answer yet returns `.pending`, starts the measurement in the background and lets the caller carry on (Glass treats it
/// as an unreadable wallpaper and goes smoked). The entry is keyed on the picture's path and modification time and the
/// region, so replacing the file or moving the pill measures again.
@MainActor
final class GlassBackdropCache {
    typealias Measure = @Sendable (_ file: URL, _ screenFrame: CGRect, _ region: CGRect) -> GlassPillPolicy.Backdrop?

    struct Key: Hashable, Sendable {
        var path: String
        var modified: TimeInterval
        var x: Int, y: Int, width: Int, height: Int

        init(file: URL, modified: Date?, region: CGRect) {
            path = file.path
            self.modified = modified?.timeIntervalSince1970 ?? 0
            x = Int(region.minX.rounded())
            y = Int(region.minY.rounded())
            width = Int(region.width.rounded())
            height = Int(region.height.rounded())
        }
    }

    enum Lookup: Equatable {
        case ready(GlassPillPolicy.Backdrop?)
        case pending
    }

    static let shared = GlassBackdropCache()

    private let measure: Measure
    private let modificationDate: (URL) -> Date?
    private var entries: [Int: (key: Key, backdrop: GlassPillPolicy.Backdrop?)] = [:]
    private var inFlight: [Int: Key] = [:]
    /// The newest key asked for on each screen. A result for any other key is stale and is dropped, so a slow
    /// measurement of an old picture or region can't overwrite the answer for the current one.
    private var latest: [Int: Key] = [:]
    private var observing = false
    /// The settings the system-wide prewarm reads, replaced by the pill's own when it starts observing.
    private var settings: UserDefaults = .standard

    init(
        measure: @escaping Measure = GlassBackdropSampler.measure,
        modificationDate: @escaping (URL) -> Date? = { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    ) {
        self.measure = measure
        self.modificationDate = modificationDate
    }

    func key(file: URL, region: CGRect) -> Key {
        Key(file: file, modified: modificationDate(file), region: region)
    }

    /// The measured backdrop for `screen` (any stable id) if it is cached for this file and region; otherwise starts a
    /// background measurement and answers `.pending`. Never decodes on the calling thread.
    func lookup(screen: Int, file: URL, screenFrame: CGRect, region: CGRect) -> Lookup {
        let key = key(file: file, region: region)
        if let entry = entries[screen], entry.key == key { return .ready(entry.backdrop) }
        prewarm(screen: screen, file: file, screenFrame: screenFrame, region: region)
        return .pending
    }

    /// Measures in the background unless the answer is cached or already on its way. The returned task finishes when the
    /// result is stored; nil when there was nothing to do.
    @discardableResult
    func prewarm(screen: Int, file: URL, screenFrame: CGRect, region: CGRect) -> Task<Void, Never>? {
        let key = key(file: file, region: region)
        if entries[screen]?.key == key || inFlight[screen] == key { return nil }
        latest[screen] = key
        inFlight[screen] = key
        let measure = measure
        return Task.detached(priority: .utility) { [weak self] in
            let result = measure(file, screenFrame, region)
            await self?.finish(screen: screen, key: key, backdrop: result)
        }
    }

    /// The measured backdrop, waiting for it when it isn't cached. The decode runs off the main thread, so the caller
    /// suspends instead of blocking. This is the same measurement `lookup` stores, for a caller that can wait for it.
    func resolve(screen: Int, file: URL, screenFrame: CGRect, region: CGRect) async -> GlassPillPolicy.Backdrop? {
        let key = key(file: file, region: region)
        if let entry = entries[screen], entry.key == key { return entry.backdrop }
        latest[screen] = key
        let measure = measure
        let result = await Task.detached(priority: .userInitiated) { measure(file, screenFrame, region) }.value
        finish(screen: screen, key: key, backdrop: result)
        return result
    }

    private func finish(screen: Int, key: Key, backdrop: GlassPillPolicy.Backdrop?) {
        if inFlight[screen] == key { inFlight[screen] = nil }
        guard latest[screen] == key else { return }
        entries[screen] = (key, backdrop)
    }
}

// MARK: System wiring

extension GlassBackdropCache {
    static func screenID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    func lookup(screen: NSScreen, region: CGRect) -> Lookup {
        guard let file = NSWorkspace.shared.desktopImageURL(for: screen) else { return .ready(nil) }
        return lookup(screen: Self.screenID(screen), file: file, screenFrame: screen.frame, region: region)
    }

    /// Measures the wallpaper behind the held pill on every screen, at the size the pill will have there, so the first
    /// hotkey press finds the answer waiting. Only while Glass is the chosen look.
    func prewarmAll(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? settings
        guard PillSkinPreference.current(defaults) == .glass else { return }
        let size = PillSizePreference.current(defaults)
        for screen in NSScreen.screens {
            guard let file = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            let region = Self.heldRegion(frame: screen.frame, visibleFrame: screen.visibleFrame, backing: screen.backingScaleFactor, size: size)
            prewarm(screen: Self.screenID(screen), file: file, screenFrame: screen.frame, region: region)
        }
    }

    /// Where the held pill body sits on a screen, in screen coordinates: centred, at the bottom of the visible frame, at
    /// the size the pill resolves to there. The pill and the Appearance preview both measure this region.
    static func heldRegion(frame: CGRect, visibleFrame: CGRect, backing: CGFloat, size: PillSize) -> CGRect {
        let scale = size.resolved(visibleWidth: visibleFrame.width)
        let panel = PillGeometry.panelSize(for: scale)
        let origin = PillPlacement.origin(
            pointer: CGPoint(x: frame.midX, y: frame.midY),
            screens: [PillPlacement.Screen(frame: frame, visibleFrame: visibleFrame)],
            panelSize: panel, pillPadding: PillGeometry.verticalMargin
        ) ?? frame.origin
        // The pill's panel is placed on whole points (rounded down), so the region has to be too, or the key never matches.
        let placed = CGPoint(x: origin.x.rounded(.down), y: origin.y.rounded(.down))
        return GlassPillView.heldBodyRegion(bounds: panel, size: scale, backing: backing).offsetBy(dx: placed.x, dy: placed.y)
    }

    /// Prewarms now and again whenever the desktop could have changed: a Space switch (each Space can have its own
    /// picture), a display change, or the system's desktop notification. A picture swapped without any of those is
    /// caught by the modification time on the next lookup, which then answers pending and measures for the press after.
    func startObserving(defaults: UserDefaults = .standard) {
        settings = defaults
        guard !observing else {
            prewarmAll()
            return
        }
        observing = true
        let refresh: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in GlassBackdropCache.shared.prewarmAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: refresh
        )
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: refresh
        )
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.desktop"), object: nil, queue: .main, using: refresh
        )
        // A look or size change in Settings moves the region the next press samples, so measure it before that press.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: refresh
        )
        prewarmAll()
    }
}
