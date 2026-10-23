import Foundation

@MainActor final class AppTermination {
    private var work: Task<Void, Never>?

    func begin(
        preserve: @escaping @MainActor () async -> Bool,
        settleClipboard: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        guard work == nil else { return }
        work = Task {
            let ready = await preserve()
            if ready { await settleClipboard() } else { work = nil }
            reply(ready)
        }
    }
}
