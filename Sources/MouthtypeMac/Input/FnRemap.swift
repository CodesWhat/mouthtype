import FnRemapKit
import Foundation

/// Opt-in, unproven on macOS 26: remaps Fn to F19 at the HID layer while the app runs so the system Globe
/// action never fires. Off by default. Reads before it writes, merges with the user's own mapping, and removes
/// only its own entry. A marker in UserDefaults records the mapping it found, so the next launch can undo it
/// if the app died with it applied.
@MainActor
public final class FnRemap {
    static let markerKey = "FnRemapApplied"
    static let originalKey = "FnRemapOriginal"
    static let originalWasUnsetKey = "FnRemapOriginalWasUnset"

    public enum Outcome: Equatable, Sendable {
        case applied
        case alreadyApplied
        case restored
        /// Nothing to undo.
        case clean
        case failed(String)
    }

    private let store: any KeyMappingStore
    private let defaults: UserDefaults
    private let ours = FnRemapMapping.entry()
    private var signalSources: [DispatchSourceSignal] = []
    private var terminationRequested = false
    /// Replaced in tests; the real thing ends the process.
    var exitProcess: (Int32) -> Void = { exit($0) }
    /// The last resort when the main queue is wedged, so it can't touch the actor. Replaced in tests.
    var hardExit: @Sendable (Int32) -> Void = { exit($0) }

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(store: HIDKeyMappingStore(), defaults: defaults)
    }

    init(store: any KeyMappingStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
    }

    public var isApplied: Bool { defaults.bool(forKey: Self.markerKey) }

    /// What the mapping holds right now, for logging. Unset reads as "unset".
    public func currentDescription() -> String {
        do {
            guard let mapping = try store.read() else { return "unset" }
            return mapping.map { entry in
                entry.sorted { $0.key < $1.key }.map { "\($0.key)=0x\(String($0.value, radix: 16))" }.joined(separator: ",")
            }.joined(separator: " | ")
        } catch {
            return "unreadable (\(error))"
        }
    }

    public func apply() -> Outcome {
        if isApplied { return .alreadyApplied }
        let original: [FnRemapMapping.Entry]?
        do {
            original = try store.read()
        } catch {
            return .failed("could not read the current mapping: \(error)")
        }
        // The marker goes first: if we die between the write and the return, the next launch still knows to undo it.
        saveMarker(original: original)
        let merged = FnRemapMapping.merging(existing: original ?? [], ours: ours)
        guard store.write(merged) else {
            clearMarker()
            return .failed("the HID system refused the write")
        }
        guard let readBack = try? store.read(), readBack.contains(ours) else {
            _ = restore()
            return .failed("the mapping did not read back after writing")
        }
        Log.hotkey.info("fn remap applied")
        return .applied
    }

    /// Removes our entry and puts back whatever it displaced. Verified by reading back; the marker stays if that fails.
    /// A property that was never set comes back as an empty array: the HID system has no way to unset it
    /// (an empty array, kCFNull and `hidutil` null were all tried). Both mean no mapping.
    public func restore() -> Outcome {
        guard isApplied else { return .clean }
        let original = savedOriginal()
        let current: [FnRemapMapping.Entry]
        do {
            current = try store.read() ?? []
        } catch {
            return .failed("could not read the current mapping: \(error)")
        }
        let target = FnRemapMapping.restoring(current: current, ours: ours, original: original ?? [])
        guard store.write(target) else { return .failed("the HID system refused the restore") }
        let readBack = (try? store.read()) ?? nil
        guard (readBack ?? []) == target else { return .failed("the restored mapping did not read back") }
        clearMarker()
        Log.hotkey.info("fn remap restored")
        return .restored
    }

    /// At launch: undo a remap a previous run died with.
    public func restoreIfStale() -> Outcome {
        guard isApplied else { return .clean }
        Log.hotkey.warning("fn remap was left applied by a previous run; restoring")
        return restore()
    }

    /// Handles SIGTERM and SIGINT on the main queue. Call once the remap is applied.
    ///
    /// With `requestTermination` (the app) the signal goes into the normal quit path, so take preservation, the
    /// clipboard lease and the audio unmute all run, and Fn is restored by that teardown. If the quit stalls or is
    /// cancelled, after `fallbackDelay` the mapping is restored and the process exits anyway; if the main queue is
    /// blocked (a modal alert) or wedged too, a background timer exits and the fn guard restores the mapping. A second signal does the same
    /// immediately. Without it (the diagnostic probes) the handler restores and exits at once.
    public func installSignalHandlers(
        signals: [Int32] = [SIGTERM, SIGINT],
        requestTermination: (@MainActor () -> Void)? = nil,
        fallbackDelay: TimeInterval = 10
    ) {
        guard signalSources.isEmpty else { return }
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleSignal(requestTermination: requestTermination, fallbackDelay: fallbackDelay)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func handleSignal(requestTermination: (@MainActor () -> Void)?, fallbackDelay: TimeInterval, hardGrace: TimeInterval = 5) {
        guard let requestTermination, !terminationRequested else {
            _ = restore()
            exitProcess(0)
            return
        }
        terminationRequested = true
        // Both deadlines are armed before the request: NSApp.terminate can block this thread in a modal alert or
        // wait on a stalled save, and nothing after it would run. The background one doesn't need the main queue.
        let hardExit = self.hardExit
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [weak self] in
            MainActor.assumeIsolated {
                Log.hotkey.error("quit after signal stalled, restoring the fn mapping and exiting")
                _ = self?.restore()
                self?.exitProcess(0)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + fallbackDelay + hardGrace) { hardExit(0) }
        requestTermination()
    }

    // MARK: - Marker

    private func saveMarker(original: [FnRemapMapping.Entry]?) {
        defaults.set(true, forKey: Self.markerKey)
        defaults.set(original == nil, forKey: Self.originalWasUnsetKey)
        defaults.set((original ?? []).map { $0.mapValues { NSNumber(value: $0) } }, forKey: Self.originalKey)
    }

    private func savedOriginal() -> [FnRemapMapping.Entry]? {
        if defaults.bool(forKey: Self.originalWasUnsetKey) { return nil }
        let stored = defaults.array(forKey: Self.originalKey) as? [[String: NSNumber]] ?? []
        return stored.map { $0.mapValues { $0.int64Value } }
    }

    private func clearMarker() {
        defaults.removeObject(forKey: Self.markerKey)
        defaults.removeObject(forKey: Self.originalKey)
        defaults.removeObject(forKey: Self.originalWasUnsetKey)
    }
}
