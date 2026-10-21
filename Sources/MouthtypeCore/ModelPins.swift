import FluidAudio
import Foundation
import WhisperKit

/// The Hugging Face commits the speech models are downloaded at. docs/SECURITY.md points here.
/// These are the `main` commits as of 2026-10-21, so a fresh download matches what the app already resolved.
/// To bump one, fetch https://huggingface.co/api/models/<repo>/revision/main `.sha` and update it here.
public enum ModelPins {
    public struct Pin: Sendable, Equatable {
        public let repo: String
        public let revision: String
    }

    public static let parakeetV3 = Pin(repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe")
    public static let parakeetV2 = Pin(repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml", revision: "ee09c569f73759e6d44c9bd16766f477b2b36d39")
    public static let ctc110m = Pin(repo: "FluidInference/parakeet-ctc-110m-coreml", revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa")
    public static let sileroVAD = Pin(repo: "FluidInference/silero-vad-coreml", revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96")
    public static let whisperKit = Pin(repo: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482")

    public static let all: [Pin] = [parakeetV3, parakeetV2, ctc110m, sileroVAD, whisperKit]

    /// FluidAudio takes revisions only through the process-wide `ModelRegistry.revisionOverrides`, keyed by repo path.
    /// The keys come from FluidAudio's own `Repo` enum so a renamed upstream repo fails to match loudly in tests.
    static let fluidAudioRevisions: [String: String] = [
        Repo.parakeetV3.remotePath: parakeetV3.revision,
        Repo.parakeetV2.remotePath: parakeetV2.revision,
        Repo.parakeetCtc110m.remotePath: ctc110m.revision,
        Repo.vad.remotePath: sileroVAD.revision,
    ]

    private static let installed: Void = {
        ModelRegistry.revisionOverrides.merge(fluidAudioRevisions) { _, pinned in pinned }
    }()

    /// Registers the FluidAudio pins. Idempotent; call before any FluidAudio download.
    static func installFluidAudioRevisions() {
        _ = installed
    }
}

/// WhisperKit 1.1.1's `WhisperKit.download(variant:)` has no revision parameter and always resolves `main`.
/// This is its variant lookup on top of `HubApiWrapper`, which does take one.
enum WhisperModelFetch {
    typealias ListFiles = @Sendable (_ globs: [String], _ revision: String) async throws -> [String]
    typealias Snapshot = @Sendable (_ globs: [String], _ revision: String) async throws -> URL

    static func download(
        variant: String,
        revision: String = ModelPins.whisperKit.revision,
        listFiles: ListFiles,
        snapshot: Snapshot
    ) async throws -> URL {
        var searchPath = "*\(variant)/*"
        var folders = try await topLevelFolders(listFiles([searchPath], revision))
        if folders.count != 1 {
            searchPath = "*openai*\(variant)/*"
            folders = try await topLevelFolders(listFiles([searchPath], revision))
        }
        guard folders.count == 1, let folder = folders.first else {
            throw WhisperError.modelsUnavailable(
                "\(folders.count > 1 ? "Multiple" : "No") models found matching \"\(searchPath)\" in \(ModelPins.whisperKit.repo)"
            )
        }
        let root = try await snapshot([searchPath], revision)
        return root.appending(path: folder)
    }

    private static func topLevelFolders(_ files: [String]) -> Set<String> {
        Set(files.compactMap { $0.components(separatedBy: "/").first })
    }

    static func download(variant: String) async throws -> URL {
        let hub = HubApiWrapper()
        let repo = HubApiWrapper.Repo(id: ModelPins.whisperKit.repo, type: .models)
        return try await download(
            variant: variant,
            listFiles: { globs, revision in try await hub.getFilenames(from: repo, revision: revision, matching: globs) },
            snapshot: { globs, revision in try await hub.snapshot(from: repo, revision: revision, matching: globs) }
        )
    }
}
