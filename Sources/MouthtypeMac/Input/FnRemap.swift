import Foundation
import IOKit.hid

/// Pure merge and restore of the `UserKeyMapping` array (Apple TN2450). Dictionary in, dictionary out.
enum FnRemapMapping {
    typealias Entry = [String: Int64]

    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Usage page 0xFF (Apple vendor top case) usage 0x03 (keyboard Fn), as `page << 32 | usage`.
    /// IOKit's public headers don't define it. Confirmed by enumerating the built-in keyboard's elements:
    /// it exposes exactly this page/usage pair.
    static let fnSource: Int64 = 0xFF_0000_0003
    /// Keyboard page 0x07 usage 0x6E (F19). The matching virtual key code is `fnDestinationKeyCode`.
    static let fnDestination: Int64 = 0x7_0000_006E
    /// kVK_F19.
    static let fnDestinationKeyCode: UInt16 = 80

    static func entry(src: Int64 = fnSource, dst: Int64 = fnDestination) -> Entry {
        [srcKey: src, dstKey: dst]
    }

    static func isOurs(_ entry: Entry, ours: Entry) -> Bool {
        entry == ours
    }

    /// The user's mapping with ours added. An entry that already maps our source is displaced
    /// (a source can map to one destination); `restoring` puts it back.
    static func merging(existing: [Entry], ours: Entry) -> [Entry] {
        existing.filter { $0[srcKey] != ours[srcKey] } + [ours]
    }

    /// `current` with our entry removed, and any original entry we displaced put back.
    /// Entries other apps or the user added since are kept.
    static func restoring(current: [Entry], ours: Entry, original: [Entry]) -> [Entry] {
        current.filter { !isOurs($0, ours: ours) } + original.filter { $0[srcKey] == ours[srcKey] }
    }
}

/// Reads and writes the HID system's key mapping.
protocol KeyMappingStore {
    /// nil when the property is unset. Throws when it holds something this code doesn't understand.
    func read() throws -> [FnRemapMapping.Entry]?
    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool
}

enum KeyMappingError: Error, Equatable {
    case unsupportedShape
}

/// `IOHIDEventSystemClient` property access, the public API TN2450 points at.
struct HIDKeyMappingStore: KeyMappingStore {
    static var propertyKey: CFString { "UserKeyMapping" as CFString }

    func read() throws -> [FnRemapMapping.Entry]? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let value = IOHIDEventSystemClientCopyProperty(client, Self.propertyKey) else { return nil }
        guard let array = value as? [[String: Any]] else { throw KeyMappingError.unsupportedShape }
        return try array.map { dictionary in
            var entry: FnRemapMapping.Entry = [:]
            for (key, raw) in dictionary {
                guard let number = raw as? NSNumber else { throw KeyMappingError.unsupportedShape }
                entry[key] = number.int64Value
            }
            return entry
        }
    }

    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let array = mapping.map { entry in entry.mapValues { NSNumber(value: $0) } } as NSArray
        return IOHIDEventSystemClientSetProperty(client, Self.propertyKey, array)
    }
}

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

    /// Restore on SIGTERM and SIGINT, then quit. Call once the remap is applied.
    public func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.restore()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
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
