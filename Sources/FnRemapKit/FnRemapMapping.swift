import Foundation

/// Pure merge and restore of the `UserKeyMapping` array (Apple TN2450). Dictionary in, dictionary out.
public enum FnRemapMapping {
    public typealias Entry = [String: Int64]

    public static let srcKey = "HIDKeyboardModifierMappingSrc"
    public static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Usage page 0xFF (Apple vendor top case) usage 0x03 (keyboard Fn), as `page << 32 | usage`.
    /// IOKit's public headers don't define it. Confirmed by enumerating the built-in keyboard's elements:
    /// it exposes exactly this page/usage pair.
    public static let fnSource: Int64 = 0xFF_0000_0003
    /// Keyboard page 0x07 usage 0x6E (F19). The matching virtual key code is `fnDestinationKeyCode`.
    public static let fnDestination: Int64 = 0x7_0000_006E
    /// kVK_F19.
    public static let fnDestinationKeyCode: UInt16 = 80

    public static func entry(src: Int64 = fnSource, dst: Int64 = fnDestination) -> Entry {
        [srcKey: src, dstKey: dst]
    }

    public static func isOurs(_ entry: Entry, ours: Entry) -> Bool {
        entry == ours
    }

    /// The user's mapping with ours added. An entry that already maps our source is displaced
    /// (a source can map to one destination); `restoring` puts it back.
    public static func merging(existing: [Entry], ours: Entry) -> [Entry] {
        existing.filter { $0[srcKey] != ours[srcKey] } + [ours]
    }

    /// `current` with our entry removed, and any original entry we displaced put back.
    /// Entries other apps or the user added since are kept.
    public static func restoring(current: [Entry], ours: Entry, original: [Entry]) -> [Entry] {
        let kept = current.filter { !isOurs($0, ours: ours) }
        // Skip what is already there: the guard may have put it back before a later restore runs.
        return kept + original.filter { $0[srcKey] == ours[srcKey] && !kept.contains($0) }
    }
}
