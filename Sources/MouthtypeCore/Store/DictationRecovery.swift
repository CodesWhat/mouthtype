import Foundation

/// A dictation a crash or quit cut off whose audio is still on disk.
public struct RecoverableDictation: Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var audioURL: URL
    public var seconds: Double
    /// The audio is only the in-progress copy of a recording; no archived WAV was ever written.
    public var isPartial: Bool
}

/// What a launch found: the newest dictation worth offering and how many older ones were set aside.
public struct RecoveryScan: Sendable, Equatable {
    public var newest: RecoverableDictation?
    /// Recoverable rows kept without an automatic offer. Their audio stays available in Saved Recordings.
    public var olderCount: Int
    /// Rows with no audio left, ended as failed.
    public var lostCount: Int
}

public enum DictationRecovery {
    /// How far back a launch looks for a dictation to offer.
    public static let window: TimeInterval = 24 * 3600
    public static let interruptedMessage = "interrupted"

    public static func saved(
        store: TranscriptStore, archive: AudioArchive, now: Date, launchedAt: Date
    ) throws -> [RecoverableDictation] {
        try store.savedRecordingCandidates(from: now.addingTimeInterval(-AudioArchive.defaultRetention), before: launchedAt)
            .compactMap { row in
                guard let audio = audio(for: row, archive: archive) else { return nil }
                return RecoverableDictation(
                    id: row.id, startedAt: Date(timeIntervalSince1970: row.startedAt), audioURL: audio.url,
                    seconds: audio.seconds, isPartial: audio.url == archive.partialURL(for: row.id)
                )
            }
    }

    /// Finds rows from the last `window` that began before `launchedAt` and never ended, and ends every one of them
    /// as failed ("interrupted") so no later launch offers it again. The audio stays on disk. A row's audio is its
    /// archived WAV, or failing that the in-progress copy a recording leaves. Newer ended activity suppresses the
    /// automatic offer without removing any saved audio.
    public static func scan(
        store: TranscriptStore, archive: AudioArchive, now: Date, launchedAt: Date, window: TimeInterval = window
    ) throws -> RecoveryScan {
        let latestTerminalStart = try store.latestTerminalStartedAt()
        let rows = try store.unfinished(from: now.addingTimeInterval(-window), before: launchedAt)
        var recoverable: [RecoverableDictation] = []
        var lost = 0
        for row in rows {
            try store.finish(row.id, status: .failed, errorMessage: interruptedMessage)
            guard let audio = audio(for: row, archive: archive) else {
                lost += 1
                continue
            }
            recoverable.append(RecoverableDictation(
                id: row.id, startedAt: Date(timeIntervalSince1970: row.startedAt), audioURL: audio.url,
                seconds: audio.seconds, isPartial: audio.url == archive.partialURL(for: row.id)
            ))
        }
        var newest = recoverable.first
        if let latestTerminalStart, let candidate = newest, latestTerminalStart > candidate.startedAt { newest = nil }
        return RecoveryScan(newest: newest, olderCount: recoverable.count - (newest == nil ? 0 : 1), lostCount: lost)
    }

    private static func audio(for row: DictationRecord, archive: AudioArchive) -> (url: URL, seconds: Double)? {
        var candidates: [URL] = []
        if let path = row.audioPath { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(archive.url(for: row.id))
        candidates.append(archive.partialURL(for: row.id))
        for url in candidates {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 44 else { continue }
            return (url, Double(size - 44) / Double(AudioArchive.sampleRate * 2))
        }
        return nil
    }
}
