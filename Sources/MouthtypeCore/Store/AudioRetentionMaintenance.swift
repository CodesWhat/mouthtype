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
        // A missing, unreadable or empty directory (an unmounted or remounted-empty folder) says nothing about the files, so
        // only a non-empty listing can identify missing files beyond those the policy just removed. Paths are read first:
        // a pointer is set only after its file exists,
        // so the later listing contains every file that was there. A row whose archive file or partial is listed keeps its
        // pointer even when the stored absolute path went stale. An existing stored path also keeps its pointer when the
        // recording lives outside the current archive.
        let paths = try store.audioPaths()
        let listed = archive.listedFileNames()
        var missing = Set(removed)
        for entry in paths {
            let absent =
                listed.map {
                    !$0.isEmpty && !$0.contains(archive.url(for: entry.id).lastPathComponent) && !$0.contains(archive.partialURL(for: entry.id).lastPathComponent)
                } ?? false
            guard missing.contains(entry.id) || absent else { continue }
            if FileManager.default.fileExists(atPath: entry.path) {
                missing.remove(entry.id)
            } else {
                missing.insert(entry.id)
            }
        }
        if !missing.isEmpty { try store.clearAudio(ids: Array(missing)) }
        return removed
    }
}
