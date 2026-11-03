import Foundation

public enum AudioRetentionMaintenance {
    /// Applies the retention policy to completed takes, and to failed and unfinished takes and crash partials once they are
    /// past `AudioArchive.recoveryGrace`. Audio with no row is never removed: after an emptied or restored database it is
    /// the only way back to those recordings. Then clears `audio_path` on rows whose file is gone, which also repairs a crash
    /// between deleting a file and clearing its pointer. Returns the row ids whose audio the policy removed.
    @discardableResult
    public static func prune(archive: AudioArchive, store: TranscriptStore, policy: AudioRetentionPolicy, now: Date) throws -> [String] {
        let completed = try store.audioRetentionCandidateIDs()
        let removed = try archive.purge(
            olderThan: policy.cutoff(at: now), maxTotalBytes: policy.maximumBytes, eligibleIDs: completed,
            recoveryIDs: try store.recoveryAudioIDs(), recoveryCutoff: now.addingTimeInterval(-AudioArchive.recoveryGrace),
            knownIDs: try store.dictationIDs())
        if !removed.isEmpty { try store.clearAudio(ids: removed) }
        // A missing, unreadable or empty directory (an unmounted or remounted-empty folder) says nothing about the files, so
        // only a non-empty listing can clear pointers. Paths are read first: a pointer is set only after its file exists,
        // so the later listing contains every file that was there. A row whose archive file or partial is listed keeps its
        // pointer even when the stored absolute path went stale.
        let paths = try store.audioPaths()
        if let listed = archive.listedFileNames(), !listed.isEmpty {
            let missing = paths.filter {
                !listed.contains(archive.url(for: $0.id).lastPathComponent) && !listed.contains(archive.partialURL(for: $0.id).lastPathComponent)
            }.map(\.id)
            if !missing.isEmpty { try store.clearAudio(ids: missing) }
        }
        return removed
    }
}
