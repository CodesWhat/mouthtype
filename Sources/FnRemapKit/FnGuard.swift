import Darwin
import Foundation

/// `mouthtype-fn-guard <parent-pid> <src-usage> <dst-usage> [<displaced-dst-usage>]`
///
/// The optional fourth usage is the destination of the user's own mapping of the same source that ours displaced
/// (Fn to Escape, say), which cleanup puts back.
public struct FnGuardArguments: Equatable, Sendable {
    public static let usage = "usage: mouthtype-fn-guard <parent-pid> <src-usage> <dst-usage> [<displaced-dst-usage>]"

    public let parent: pid_t
    public let entry: FnRemapMapping.Entry
    public let displaced: FnRemapMapping.Entry?

    public init(parent: pid_t, entry: FnRemapMapping.Entry, displaced: FnRemapMapping.Entry? = nil) {
        self.parent = parent
        self.entry = entry
        self.displaced = displaced
    }

    /// `arguments` is the full argv, program name first. Usages are decimal or 0x-prefixed hex.
    public static func parse(_ arguments: [String]) -> FnGuardArguments? {
        guard arguments.count == 4 || arguments.count == 5,
            let pid = Int32(arguments[1]), pid > 1,
            let src = usageValue(arguments[2]), let dst = usageValue(arguments[3])
        else { return nil }
        var displaced: FnRemapMapping.Entry?
        if arguments.count == 5 {
            guard let value = usageValue(arguments[4]) else { return nil }
            displaced = FnRemapMapping.entry(src: src, dst: value)
        }
        return FnGuardArguments(parent: pid, entry: FnRemapMapping.entry(src: src, dst: dst), displaced: displaced)
    }

    private static func usageValue(_ text: String) -> Int64? {
        if text.hasPrefix("0x") || text.hasPrefix("0X") { return Int64(text.dropFirst(2), radix: 16) }
        return Int64(text)
    }
}

public enum FnGuardOutcome: Equatable, Sendable {
    case removed
    /// The mapping holds no entry of ours: a clean quit already restored it.
    case alreadyGone
    case failed(String)
}

/// The guard's whole job, behind two seams: how it waits for the parent and where the mapping lives.
public enum FnGuard {
    /// Blocks until `pid` has exited, for any reason. Blocks in `kevent`, no polling. A parent that is already
    /// gone, at the start or by the time the watch registers, counts as exited.
    public static func waitForExit(of pid: pid_t) {
        if kill(pid, 0) != 0, errno == ESRCH { return }
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        // A registration error (ESRCH: the parent died just now) comes back as an EV_ERROR event, which also ends the wait.
        while kevent(queue, &change, 1, &event, 1, nil) < 0, errno == EINTR {}
    }

    /// Removes only the entry in `ours`, leaving the user's other mappings, puts back the mapping of the same source
    /// it displaced (`restoring`), and verifies by reading back. Does nothing when our entry is already gone, so a
    /// clean quit or an earlier cleanup is never repeated.
    public static func removeOurs(
        _ ours: FnRemapMapping.Entry, restoring displaced: FnRemapMapping.Entry? = nil, from store: some KeyMappingStore
    ) -> FnGuardOutcome {
        let current: [FnRemapMapping.Entry]
        do {
            current = try store.read() ?? []
        } catch {
            return .failed("could not read the current mapping: \(error)")
        }
        guard current.contains(ours) else { return .alreadyGone }
        let target = FnRemapMapping.restoring(current: current, ours: ours, original: displaced.map { [$0] } ?? [])
        guard store.write(target) else { return .failed("the HID system refused the write") }
        guard let readBack = (try? store.read()) ?? nil, !readBack.contains(ours), readBack == target else {
            return .failed("the mapping was not restored after the write")
        }
        return .removed
    }

    public static func run(
        _ arguments: FnGuardArguments, store: some KeyMappingStore,
        wait: (pid_t) -> Void = FnGuard.waitForExit(of:)
    ) -> FnGuardOutcome {
        wait(arguments.parent)
        return removeOurs(arguments.entry, restoring: arguments.displaced, from: store)
    }
}
