import Darwin
import Foundation

/// `mouthtype-fn-guard <parent-pid> <src-usage> <dst-usage>`
public struct FnGuardArguments: Equatable, Sendable {
    public static let usage = "usage: mouthtype-fn-guard <parent-pid> <src-usage> <dst-usage>"

    public let parent: pid_t
    public let entry: FnRemapMapping.Entry

    public init(parent: pid_t, entry: FnRemapMapping.Entry) {
        self.parent = parent
        self.entry = entry
    }

    /// `arguments` is the full argv, program name first. Usages are decimal or 0x-prefixed hex.
    public static func parse(_ arguments: [String]) -> FnGuardArguments? {
        guard arguments.count == 4,
              let pid = Int32(arguments[1]), pid > 1,
              let src = usageValue(arguments[2]), let dst = usageValue(arguments[3]) else { return nil }
        return FnGuardArguments(parent: pid, entry: FnRemapMapping.entry(src: src, dst: dst))
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

    /// Removes only the entry in `ours`, leaving the user's other mappings, and verifies by reading back.
    public static func removeOurs(_ ours: FnRemapMapping.Entry, from store: some KeyMappingStore) -> FnGuardOutcome {
        let current: [FnRemapMapping.Entry]
        do {
            current = try store.read() ?? []
        } catch {
            return .failed("could not read the current mapping: \(error)")
        }
        guard current.contains(ours) else { return .alreadyGone }
        let target = current.filter { !FnRemapMapping.isOurs($0, ours: ours) }
        guard store.write(target) else { return .failed("the HID system refused the write") }
        guard let readBack = (try? store.read()) ?? nil, !readBack.contains(ours) else {
            return .failed("our entry was still there after the write")
        }
        return .removed
    }

    public static func run(
        _ arguments: FnGuardArguments, store: some KeyMappingStore,
        wait: (pid_t) -> Void = FnGuard.waitForExit(of:)
    ) -> FnGuardOutcome {
        wait(arguments.parent)
        return removeOurs(arguments.entry, from: store)
    }
}
