import Foundation

/// The apps where a finished dictation is followed by a Return, kept in UserDefaults by bundle ID. Empty by default,
/// so nothing is ever sent until the user opts an app in.
struct SendAfterInsertSettings {
    enum Key {
        static let bundleIDs = "sendAfterInsertBundleIDs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Key.bundleIDs) ?? [])
    }

    func isEnabled(bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleIDs.contains(bundleID)
    }

    func add(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        store(bundleIDs.union([bundleID]))
    }

    func remove(_ bundleID: String) {
        store(bundleIDs.subtracting([bundleID]))
    }

    private func store(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Key.bundleIDs)
    }
}
