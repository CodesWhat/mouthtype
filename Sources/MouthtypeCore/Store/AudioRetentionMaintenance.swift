import Foundation

public enum AudioRetentionMaintenance {
    /// Applies the retention policy to completed takes, lets failed and unfinished takes (and crash partials) go once past
    /// `AudioArchive.recoveryGrace`, removes old audio with no row, and clears `audio_path` on every row whose file is gone,
    /// which also repairs a crash between deleting a file and clearing its pointer. Returns the row ids whose audio the
    /// policy removed.
    @discardableResult
    public static func prune(archive: AudioArchive, store: TranscriptStore, policy: AudioRetentionPolicy, now: Date) throws -> [String] {
        let completed = try store.audioRetentionCandidateIDs()
        let removed = try archive.purge(
            olderThan: policy.cutoff(at: now), maxTotalBytes: policy.maximumBytes, eligibleIDs: completed,
            recoveryIDs: try store.recoveryAudioIDs(), recoveryCutoff: now.addingTimeInterval(-AudioArchive.recoveryGrace),
            knownIDs: try store.dictationIDs(), orphanCutoff: now.addingTimeInterval(-AudioArchive.orphanGrace))
        if !removed.isEmpty { try store.clearAudio(ids: removed) }
        let manager = FileManager.default
        // The stored path is absolute and can go stale after a rename, so the archive's own file for the id counts too.
        let missing = try store.audioPaths().filter {
            !manager.fileExists(atPath: $0.path) && !manager.fileExists(atPath: archive.url(for: $0.id).path)
                && !manager.fileExists(atPath: archive.partialURL(for: $0.id).path)
        }.map(\.id)
        if !missing.isEmpty { try store.clearAudio(ids: missing) }
        return removed
    }
}
