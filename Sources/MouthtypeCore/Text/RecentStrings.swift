import Foundation

/// The few most recent results of a derivation from a list of strings, matched by value. A library that is the
/// same across takes (the array usually shares one buffer, so the comparison is immediate) skips the rebuild, and
/// an edited library is a different list and builds fresh.
final class RecentStrings<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: [String], value: Value)] = []
    private let capacity: Int

    init(capacity: Int = 4) { self.capacity = capacity }

    func value(for key: [String], build: ([String]) -> Value) -> Value {
        lock.lock()
        if let at = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: at)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        let value = build(key)
        lock.lock(); defer { lock.unlock() }
        entries.insert((key, value), at: 0)
        if entries.count > capacity { entries.removeLast() }
        return value
    }
}
