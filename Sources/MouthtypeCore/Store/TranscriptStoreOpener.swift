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
        opener: (URL) throws -> TranscriptStore = { try TranscriptStore(url: $0) },
        mover: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> StoreOpenOutcome {
        var lastError: Error
        do { return StoreOpenOutcome(store: try opener(url)) } catch { lastError = error }

        if isBusy(lastError) {
            sleep(retryDelay)
            do { return StoreOpenOutcome(store: try opener(url)) } catch { lastError = error }
        }

        if isDamaged(lastError) {
            let audio = audioDirectory ?? url.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true)
            let moved: Quarantined
            switch quarantine(url, audio: audio, at: now(), move: mover) {
            case .success(let result): moved = result
            case .failure(let failure):
                var text = "the damaged file couldn't be set aside (\(describe(failure.error)))"
                if !failure.leftover.isEmpty {
                    text += ". Some files could not be moved back and are still named " + failure.leftover.map(\.lastPathComponent).joined(separator: ", ")
                }
                return StoreOpenOutcome(failure: text)
            }
            do {
                return StoreOpenOutcome(store: try opener(url), quarantinedTo: moved.database, quarantinedAudioTo: moved.audio)
            } catch {
                return StoreOpenOutcome(quarantinedTo: moved.database, quarantinedAudioTo: moved.audio, failure: describe(error))
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

    struct Quarantined {
        var database: URL
        var audio: URL?
    }

    struct QuarantineFailure: Error {
        var error: Error
        /// Files that were moved and could not be moved back, at their quarantine names. Empty when the rollback was complete.
        var leftover: [URL]
    }

    /// Renames the audio folder, then -shm, -wal and the database last, to `<name>.corrupt-<timestamp>`. The database goes last so
    /// a failure part way never leaves a moved database beside a -wal SQLite could discard. If any move fails the ones already
    /// made are moved back (never deleted), so nothing is left half-quarantined unless a move back fails too.
    static func quarantine(
        _ url: URL, audio: URL, at date: Date,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> Result<Quarantined, QuarantineFailure> {
        let stamp = Self.stamp(date)
        let fm = FileManager.default
        let sources = [audio, URL(fileURLWithPath: url.path + "-shm"), URL(fileURLWithPath: url.path + "-wal"), url]
        var done: [(from: URL, to: URL)] = []
        func rollBack(_ error: Error) -> Result<Quarantined, QuarantineFailure> {
            var leftover: [URL] = []
            for pair in done.reversed() {
                do { try move(pair.to, pair.from) } catch { leftover.append(pair.to) }
            }
            return .failure(QuarantineFailure(error: error, leftover: leftover))
        }
        for source in sources where fm.fileExists(atPath: source.path) {
            var target = URL(fileURLWithPath: source.path + ".corrupt-" + stamp)
            var n = 1
            while fm.fileExists(atPath: target.path) {
                n += 1
                target = URL(fileURLWithPath: source.path + ".corrupt-" + stamp + "-\(n)")
            }
            do { try move(source, target) } catch { return rollBack(error) }
            done.append((source, target))
        }
        let audioTarget = done.first { $0.from == audio }?.to
        let dbTarget = done.first { $0.from == url }?.to ?? url
        return .success(Quarantined(database: dbTarget, audio: audioTarget))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
