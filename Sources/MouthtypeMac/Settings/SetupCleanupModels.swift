import MouthtypeCore

/// One cleanup model as the setup sheet lists it.
struct CleanupModelStatus: Equatable, Identifiable {
    var level: CleanupLevel
    var name: String
    var sizeMB: Int
    var status: ModelDownloadStatus
    /// The level the user's cleanup setting points at.
    var selected: Bool

    var id: CleanupLevel { level }
}

/// What the setup sheet needs from the cleanup models, so it never reaches into the host.
@MainActor protocol CleanupModelListing {
    func cleanupModels() -> [CleanupModelStatus]
    func downloadCleanupModel(_ level: CleanupLevel)
    func cancelCleanupDownload(_ level: CleanupLevel)
}
