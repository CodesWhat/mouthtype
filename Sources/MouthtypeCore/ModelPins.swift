import CryptoKit
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

    /// The tokenizer files WhisperKit loads for a variant, at an exact commit of the repo it would otherwise resolve at `main`.
    /// The digests are SHA-256 of the files at that commit, reviewed 2026-11-18. To bump one, fetch the repo's
    /// `revision/main` `.sha`, download the three files at it, and update the commit and digests together.
    public struct TokenizerPin: Sendable, Equatable {
        public let repo: String
        public let revision: String
        /// File name to lowercase hex SHA-256.
        public let files: [String: String]
    }

    /// `openai/whisper-large-v3` is the tokenizer WhisperKit picks for the turbo model (`large-v3-v20240930_turbo`).
    public static let whisperTokenizerLargeV3 = TokenizerPin(
        repo: "openai/whisper-large-v3",
        revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
        files: [
            "config.json": "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b",  // gitleaks:allow (SHA-256 of a public file)
            "tokenizer.json": "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca",  // gitleaks:allow (SHA-256 of a public file)
            "tokenizer_config.json": "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389",  // gitleaks:allow (SHA-256 of a public file)
        ]
    )
    public static let whisperTokenizerSmallEn = TokenizerPin(
        repo: "openai/whisper-small.en",
        revision: "e8727524f962ee844a7319d92be39ac1bd25655a",
        files: [
            "config.json": "3441094addfb2a31ef62ea117e95bd6e437bbad8e93d3697fe420a4a6d3603a5",  // gitleaks:allow (SHA-256 of a public file)
            "tokenizer.json": "5eb60cec1e77aeeb6869a2bb5a8e01a84c3fe5d072d75369343021fe6f5310d0",  // gitleaks:allow (SHA-256 of a public file)
            "tokenizer_config.json": "14f84bdf4b9ecdbd4738ddc81c17a1baedfc02bb93c6e049c951e15a1b40b70d",  // gitleaks:allow (SHA-256 of a public file)
        ]
    )

    /// The tokenizer pin for a Whisper variant, keyed by the variant strings `WhisperEngine` uses.
    static let whisperTokenizers: [String: TokenizerPin] = [
        WhisperEngine.turboVariant: whisperTokenizerLargeV3,
        WhisperEngine.smallEnVariant: whisperTokenizerSmallEn,
    ]

    /// Every file in a catalog variant's folder at the `whisperKit` pin, relative to that folder. This is what a snapshot of
    /// `<folder>/*` downloads: Hub matches with `fnmatch` and no flags, so `*` crosses `/` and takes the nested `.mlmodelc`
    /// contents too. To regenerate after a pin bump, list the files under each folder from
    /// https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/<revision>/<folder>?recursive=true and update the
    /// lists with the revision.
    static let whisperKitFiles: [String: [String]] = [
        WhisperEngine.turboVariant: whisperKitCommonFiles
            + [
                "TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin",
                "TextDecoderContextPrefill.mlmodelc/coremldata.bin",
                "TextDecoderContextPrefill.mlmodelc/metadata.json",
                "TextDecoderContextPrefill.mlmodelc/model.mil",
                "TextDecoderContextPrefill.mlmodelc/weights/weight.bin",
            ],
        WhisperEngine.smallEnVariant: whisperKitCommonFiles,
    ]

    private static let whisperKitCommonFiles = [
        "AudioEncoder.mlmodelc/analytics/coremldata.bin",
        "AudioEncoder.mlmodelc/coremldata.bin",
        "AudioEncoder.mlmodelc/metadata.json",
        "AudioEncoder.mlmodelc/model.mil",
        "AudioEncoder.mlmodelc/model.mlmodel",
        "AudioEncoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "MelSpectrogram.mlmodelc/metadata.json",
        "MelSpectrogram.mlmodelc/model.mil",
        "MelSpectrogram.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/analytics/coremldata.bin",
        "TextDecoder.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/metadata.json",
        "TextDecoder.mlmodelc/model.mil",
        "TextDecoder.mlmodelc/model.mlmodel",
        "TextDecoder.mlmodelc/weights/weight.bin",
        "config.json",
        "generation_config.json",
    ]

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

    /// The folder each catalog variant lives in at the pinned commit of `argmaxinc/whisperkit-coreml`. These are what the
    /// generic lookup below resolves to there.
    static let catalogFolders: [String: String] = [
        WhisperEngine.turboVariant: "openai_whisper-large-v3-v20240930_turbo",
        WhisperEngine.smallEnVariant: "openai_whisper-small.en",
    ]

    static func download(
        variant: String,
        revision: String = ModelPins.whisperKit.revision,
        cacheRoot: URL? = nil,
        listFiles: ListFiles,
        snapshot: Snapshot
    ) async throws -> URL {
        // A catalog variant's folder and files are known, so a complete cache at the pin loads with no request. Hub's
        // snapshot can't be relied on for that: it validates locally only once its path monitor reports no connection, and
        // that check doesn't compare the cached commit with the requested one.
        if let folder = catalogFolders[variant] {
            var pinnedCache: (@Sendable () -> URL?)?
            if let cacheRoot, revision == ModelPins.whisperKit.revision, let files = ModelPins.whisperKitFiles[variant] {
                pinnedCache = { cachedFolder(root: cacheRoot, folder: folder, files: files, revision: revision) }
            }
            if let cached = pinnedCache?() { return cached }
            // Anything missing or from another commit goes to the pinned snapshot, which downloads or repairs it. It skips
            // the listing, a separate request the exact folder doesn't need.
            let root = try await snapshot(["\(folder)/*"], revision)
            // A real download leaves every sidecar at the pin. Offline, the snapshot accepts a cache from any commit, so
            // one that still doesn't match is an older model and isn't loaded as the pinned one.
            if let pinnedCache, pinnedCache() == nil {
                throw WhisperError.modelsUnavailable(
                    "The cached Whisper model \(folder) doesn't match the pinned revision \(revision). Connect to the internet to update it."
                )
            }
            return root.appending(path: folder)
        }
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

    /// `<root>/<folder>` when every file in `files` is there and Hub's sidecar for it records `revision`. Hub writes one per
    /// downloaded file at `<root>/.cache/huggingface/download/<path>.metadata`: the commit, the etag and a timestamp, one per
    /// line. It records no size, and contents aren't re-hashed here, since that would read gigabytes on every launch.
    static func cachedFolder(root: URL, folder: String, files: [String], revision: String) -> URL? {
        guard !files.isEmpty else { return nil }
        let fm = FileManager.default
        let modelFolder = root.appending(path: folder)
        let sidecars = root.appending(path: ".cache/huggingface/download").appending(path: folder)
        for file in files {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: modelFolder.appending(path: file).path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let sidecar = try? String(contentsOf: sidecars.appending(path: file + ".metadata"), encoding: .utf8),
                sidecar.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) == revision
            else { return nil }
        }
        return modelFolder
    }

    private static func topLevelFolders(_ files: [String]) -> Set<String> {
        Set(files.compactMap { $0.components(separatedBy: "/").first })
    }

    static func download(variant: String) async throws -> URL {
        let hub = HubApiWrapper()
        let repo = HubApiWrapper.Repo(id: ModelPins.whisperKit.repo, type: .models)
        return try await download(
            variant: variant,
            cacheRoot: hub.localRepoLocation(repo),
            listFiles: { globs, revision in try await hub.getFilenames(from: repo, revision: revision, matching: globs) },
            snapshot: { globs, revision in try await hub.snapshot(from: repo, revision: revision, matching: globs) }
        )
    }
}

/// WhisperKit 1.1.1 loads a tokenizer from Hugging Face `main` when the model folder has none, with no digest check.
/// This fetches the tokenizer files at the pinned commit, checks them against their reviewed digests, and keeps them in a
/// revision-specific folder that WhisperKit is pointed at, so it never has a reason to go to the network.
enum WhisperTokenizerFetch {
    typealias FetchFile = @Sendable (_ repo: String, _ revision: String, _ file: String) async throws -> Data

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/pinned-vocabularies", isDirectory: true)
    }

    /// The verified folder for `variant`. A cached file that matches its digest is used without any request. Anything
    /// missing, altered or extra is replaced from the pinned commit, and bytes that don't match throw.
    static func prepare(
        variant: String,
        pins: [String: ModelPins.TokenizerPin] = ModelPins.whisperTokenizers,
        root: URL = defaultRoot,
        fetch: FetchFile = download
    ) async throws -> URL {
        guard let pin = pins[variant] else {
            throw WhisperError.tokenizerUnavailable("No pinned tokenizer for Whisper variant \(variant)")
        }
        return try await prepare(pin: pin, root: root, fetch: fetch)
    }

    static func prepare(pin: ModelPins.TokenizerPin, root: URL, fetch: FetchFile) async throws -> URL {
        guard HubDownloader.isCommitHash(pin.revision), !pin.files.isEmpty else {
            throw WhisperError.tokenizerUnavailable("Tokenizer pin for \(pin.repo) is not an exact commit")
        }
        let fm = FileManager.default
        let folder = root.appendingPathComponent(pin.repo, isDirectory: true).appendingPathComponent(pin.revision, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Hub's tokenizer loader reads these optional files when present, so an unpinned copy can't stay. Only these exact
        // names are removed: another caller's in-flight write never lands in this folder under any other name.
        for name in ["chat_template.jinja", "chat_template.json"] where pin.files[name] == nil {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        // Downloads are staged outside the pinned folder, so concurrent preparers never see each other's temp files. The
        // replacement directory is on the folder's volume, which replaceItemAt and an atomic move both require.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        for (name, digest) in pin.files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(name)
            if let cached = try? Data(contentsOf: url), sha256Hex(cached) == digest { continue }
            let data = try await fetch(pin.repo, pin.revision, name)
            guard sha256Hex(data) == digest else {
                throw WhisperError.tokenizerUnavailable("\(pin.repo)@\(pin.revision)/\(name) doesn't match its pinned SHA-256")
            }
            let staged = staging.appendingPathComponent(name)
            try data.write(to: staged)
            do {
                if fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: url)
                }
            } catch {
                // A concurrent preparer may have installed the same file first. Its bytes count only if they verify.
                guard let winner = try? Data(contentsOf: url), sha256Hex(winner) == digest else { throw error }
            }
        }
        return folder
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func download(repo: String, revision: String, file: String) async throws -> Data {
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)") else {
            throw WhisperError.tokenizerUnavailable("Invalid tokenizer URL for \(repo)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WhisperError.tokenizerUnavailable("Fetching \(repo)@\(revision)/\(file) failed")
        }
        return data
    }
}
