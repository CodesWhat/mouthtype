import Foundation

public enum AudioRetentionMaintenance {
    @discardableResult
    public static func prune(archive: AudioArchive, store: TranscriptStore, policy: AudioRetentionPolicy, now: Date) throws -> [String] {
        let completed = try store.audioRetentionCandidateIDs()
        let removed = try archive.purge(olderThan: policy.cutoff(at: now), maxTotalBytes: policy.maximumBytes, eligibleIDs: completed)
        if !removed.isEmpty { try store.clearAudio(ids: removed) }
        return removed
    }
}
