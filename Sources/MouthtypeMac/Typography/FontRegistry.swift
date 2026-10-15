import AppKit
import CoreText

/// Registers the bundled Instrument Serif, Instrument Sans and JetBrains Mono for this process. A failure is logged
/// once and the type falls back to the system fonts.
@MainActor
enum FontRegistry {
    nonisolated static let directory = "Fonts"
    nonisolated static let serifName = "InstrumentSerif-Regular"
    nonisolated static let sansNames = [
        "InstrumentSans-Regular", "InstrumentSans-Medium", "InstrumentSans-SemiBold",
    ]
    nonisolated static let monoName = "JetBrainsMono-Medium"
    nonisolated static let families = ["Instrument Serif", "Instrument Sans", "JetBrains Mono"]

    private(set) static var registered: [String]?

    /// Registers every font file under `Fonts/` in `bundle` once and returns the family names that came up. Later
    /// calls return the first result.
    @discardableResult
    static func registerBundledFonts(bundle: Bundle = .module) -> [String] {
        if let registered { return registered }
        var failed = false
        for url in fontURLs(in: bundle) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is fine (a second registration in the same process).
                let code = error.map { CFErrorGetCode($0.takeUnretainedValue()) }
                if code != Int(CTFontManagerError.alreadyRegistered.rawValue) {
                    failed = true
                    Log.app.error("font registration failed for \(url.lastPathComponent, privacy: .public)")
                }
            }
        }
        let found = families.filter { isInstalled(family: $0) }
        registered = found
        if failed || found.count != families.count {
            Log.app.error("bundled fonts incomplete (\(found.joined(separator: ", "), privacy: .public)); falling back to system fonts")
        } else {
            Log.app.info("fonts registered: \(found.joined(separator: ", "), privacy: .public)")
        }
        return found
    }

    nonisolated static func fontURLs(in bundle: Bundle) -> [URL] {
        ["ttf", "otf"].flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: directory) ?? [] }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isInstalled(family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }
}
