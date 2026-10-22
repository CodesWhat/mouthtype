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

    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var result: [String]?

    /// Whether registration ever ran on the main thread. A test seam for the launch path.
    nonisolated(unsafe) static var registeredOnMain = false

    /// Forgets the result so a test can watch a fresh registration. Fonts stay registered with the process.
    nonisolated static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        result = nil
        registeredOnMain = false
    }

    /// The families that came up, or nil until registration has finished.
    nonisolated static var registered: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    /// Registers every font file under `Fonts/` in `bundle` once and returns the family names that came up. Later
    /// calls return the first result. Safe from any thread: a caller that arrives while another thread is registering
    /// blocks until it finishes, so a draw never sees a half-registered set.
    @discardableResult
    nonisolated static func registerBundledFonts(bundle: Bundle = .module) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        if Thread.isMainThread { registeredOnMain = true }
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
        let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        let found = families.filter { installed.contains($0) }
        result = found
        if failed || found.count != families.count {
            Log.app.error("bundled fonts incomplete (\(found.joined(separator: ", "), privacy: .public)); falling back to system fonts")
        } else {
            Log.app.info("fonts registered: \(found.joined(separator: ", "), privacy: .public)")
        }
        return found
    }

    /// Starts registration on a utility queue so launch doesn't wait for it. Anything that draws with a bundled font
    /// calls `registerBundledFonts()` (or `ensureRegistered()`) first and waits for this if it is still running.
    nonisolated static func registerInBackground() {
        DispatchQueue.global(qos: .utility).async { registerBundledFonts() }
    }

    /// Cheap gate for draw paths: returns immediately once registered, otherwise registers (or waits) first.
    nonisolated static func ensureRegistered() {
        if registered == nil { registerBundledFonts() }
    }

    nonisolated static func fontURLs(in bundle: Bundle) -> [URL] {
        ["ttf", "otf"].flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: directory) ?? [] }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated static func isInstalled(family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }
}
