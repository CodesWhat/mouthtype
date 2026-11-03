import Foundation
import GRDB

/// What opening the history database came to. `store` is nil only when `failure` is set.
public struct StoreOpenOutcome {
    public var store: TranscriptStore?
    /// Where a damaged database was moved when it had to be replaced.
    public var quarantinedTo: URL?
    /// Where the audio folder went with it, so old recordings stay with their history and a sweep for WAVs without rows can't reach them.
    public var quarantinedAudioTo: URL?
    /// Why history couldn't be opened, in words fit for the user.
    public var failure: String?

    public init(store: TranscriptStore? = nil, quarantinedTo: URL? = nil, quarantinedAudioTo: URL? = nil, failure: String? = nil) {
        self.store = store
        self.quarantinedTo = quarantinedTo
        self.quarantinedAudioTo = quarantinedAudioTo
        self.failure = failure
    }

    /// The note shown after a damaged database was set aside and a fresh one opened.
    public var quarantineNotice: String? {
        quarantinedTo.map {
            var text = "History was damaged, so a new one was started. The old file is kept as \($0.lastPathComponent) next to it."
            if let audio = quarantinedAudioTo { text += " Its recordings are in \(audio.lastPathComponent)." }
            return text
        }
    }
}

public enum TranscriptStoreOpener {
    public static let busyRetryDelay: TimeInterval = 0.5

    /// Opens the store at `url`. A busy or locked file is retried once after `retryDelay` (another instance may still be quitting).
    /// A corrupt or non-SQLite file is renamed aside with its -wal and -shm, never deleted, and a fresh store is opened in its place.
    /// Anything else comes back as `failure` so the caller can keep running and say so.
    public static func open(
        url: URL = TranscriptStore.defaultURL(),
        audioDirectory: URL? = nil,
        retryDelay: TimeInterval = busyRetryDelay,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        opener: (URL) throws -> TranscriptStore = { try TranscriptStore(url: $0) }
    ) -> StoreOpenOutcome {
        var lastError: Error
        do { return StoreOpenOutcome(store: try opener(url)) } catch { lastError = error }

        if isBusy(lastError) {
            sleep(retryDelay)
            do { return StoreOpenOutcome(store: try opener(url)) } catch { lastError = error }
        }

        if isDamaged(lastError) {
            let moved: URL
            var movedAudio: URL?
            do {
                let date = now()
                moved = try quarantine(url, at: date)
                movedAudio = try quarantineDirectory(audioDirectory ?? url.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true), at: date)
            } catch {
                return StoreOpenOutcome(failure: "the damaged file couldn't be set aside (\(describe(error)))")
            }
            do {
                return StoreOpenOutcome(store: try opener(url), quarantinedTo: moved, quarantinedAudioTo: movedAudio)
            } catch {
                return StoreOpenOutcome(quarantinedTo: moved, quarantinedAudioTo: movedAudio, failure: describe(error))
            }
        }
        return StoreOpenOutcome(failure: describe(lastError))
    }

    static func isBusy(_ error: Error) -> Bool {
        guard let code = (error as? DatabaseError)?.resultCode else { return false }
        return code == .SQLITE_BUSY || code == .SQLITE_LOCKED
    }

    static func isDamaged(_ error: Error) -> Bool {
        guard let code = (error as? DatabaseError)?.resultCode else { return false }
        return code == .SQLITE_CORRUPT || code == .SQLITE_NOTADB
    }

    static func describe(_ error: Error) -> String {
        (error as? DatabaseError)?.message ?? error.localizedDescription
    }

    /// Renames the database and its -wal/-shm to `<name>.corrupt-<timestamp>`. Returns where the database itself went.
    static func quarantine(_ url: URL, at date: Date) throws -> URL {
        let stamp = Self.stamp(date)
        let fm = FileManager.default
        var movedMain = url
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            var target = URL(fileURLWithPath: source.path + ".corrupt-" + stamp)
            var n = 1
            while fm.fileExists(atPath: target.path) {
                n += 1
                target = URL(fileURLWithPath: source.path + ".corrupt-" + stamp + "-\(n)")
            }
            try fm.moveItem(at: source, to: target)
            if suffix.isEmpty { movedMain = target }
        }
        return movedMain
    }

    /// Renames a folder to `<name>.corrupt-<timestamp>`. Nil when there is no such folder.
    static func quarantineDirectory(_ directory: URL, at date: Date) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return nil }
        let stamp = Self.stamp(date)
        var target = URL(fileURLWithPath: directory.path + ".corrupt-" + stamp, isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = URL(fileURLWithPath: directory.path + ".corrupt-" + stamp + "-\(n)", isDirectory: true)
        }
        try fm.moveItem(at: directory, to: target)
        return target
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
