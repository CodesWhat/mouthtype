import FluidAudio
import Foundation
import Testing
import WhisperKit
@testable import MouthtypeCore

@Suite struct ModelPinsTests {
    private func isCommitSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    @Test func everyPinIsAFullCommitSHA() {
        for pin in ModelPins.all {
            #expect(isCommitSHA(pin.revision), "\(pin.repo) is pinned to '\(pin.revision)'")
        }
        #expect(Set(ModelPins.all.map(\.repo)).count == ModelPins.all.count)
    }

    @Test func fluidAudioReceivesEveryPinKeyedByItsRepoPath() {
        ModelPins.installFluidAudioRevisions()
        let overrides = ModelRegistry.revisionOverrides
        #expect(overrides[Repo.parakeetV3.remotePath] == ModelPins.parakeetV3.revision)
        #expect(overrides[Repo.parakeetV2.remotePath] == ModelPins.parakeetV2.revision)
        #expect(overrides[Repo.parakeetCtc110m.remotePath] == ModelPins.ctc110m.revision)
        #expect(overrides[Repo.vad.remotePath] == ModelPins.sileroVAD.revision)
        #expect(Repo.parakeetV3.remotePath == ModelPins.parakeetV3.repo)
        #expect(Repo.parakeetV2.remotePath == ModelPins.parakeetV2.repo)
        #expect(Repo.parakeetCtc110m.remotePath == ModelPins.ctc110m.repo)
        #expect(Repo.vad.remotePath == ModelPins.sileroVAD.repo)
    }

    @Test func whisperDownloadPassesThePinnedRevisionToListAndSnapshot() async throws {
        let seen = Seen()
        let folder = try await WhisperModelFetch.download(
            variant: "base.en",
            listFiles: { globs, revision in
                await seen.record(revision)
                #expect(globs == ["*base.en/*"])
                return ["openai_whisper-base.en/config.json", "openai_whisper-base.en/AudioEncoder.mlmodelc/model.mil"]
            },
            snapshot: { _, revision in
                await seen.record(revision)
                return URL(fileURLWithPath: "/tmp/models/argmaxinc/whisperkit-coreml")
            }
        )
        #expect(await seen.revisions == [ModelPins.whisperKit.revision, ModelPins.whisperKit.revision])
        #expect(folder.lastPathComponent == "openai_whisper-base.en")
    }

    @Test func whisperDisambiguatesWithTheOpenAIPrefixAtTheSameRevision() async throws {
        let seen = Seen()
        _ = try await WhisperModelFetch.download(
            variant: "large-v3",
            revision: String(repeating: "a", count: 40),
            listFiles: { globs, revision in
                await seen.record(revision)
                return globs == ["*large-v3/*"] ? ["a_large-v3/x", "b_large-v3/y"] : ["openai_whisper-large-v3/x"]
            },
            snapshot: { globs, revision in
                await seen.record(revision)
                #expect(globs == ["*openai*large-v3/*"])
                return URL(fileURLWithPath: "/tmp")
            }
        )
        #expect(await seen.revisions == Array(repeating: String(repeating: "a", count: 40), count: 3))
    }

    @Test func whisperFailsWhenTheVariantIsAmbiguous() async {
        await #expect(throws: (any Error).self) {
            _ = try await WhisperModelFetch.download(
                variant: "x",
                listFiles: { _, _ in ["a_x/1", "b_x/2"] },
                snapshot: { _, _ in URL(fileURLWithPath: "/tmp") }
            )
        }
    }

    private static let catalogFolders: [(variant: String, folder: String)] = [
        (WhisperEngine.turboVariant, "openai_whisper-large-v3-v20240930_turbo"),
        (WhisperEngine.smallEnVariant, "openai_whisper-small.en"),
    ]

    @Test func catalogVariantsMapToTheirExactFolders() {
        #expect(WhisperModelFetch.catalogFolders.count == Self.catalogFolders.count)
        for (variant, folder) in Self.catalogFolders {
            #expect(WhisperModelFetch.catalogFolders[variant] == folder)
        }
    }

    @Test func catalogVariantsResolveWithoutAListingWhenItThrows() async throws {
        for (variant, folder) in Self.catalogFolders {
            let seen = Seen()
            let root = URL(fileURLWithPath: "/tmp/models/argmaxinc/whisperkit-coreml")
            let resolved = try await WhisperModelFetch.download(
                variant: variant,
                listFiles: { _, _ in throw URLError(.notConnectedToInternet) },
                snapshot: { globs, revision in
                    await seen.record("\(globs)@\(revision)")
                    return root
                }
            )
            #expect(resolved == root.appending(path: folder))
            #expect(await seen.revisions == ["\(["\(folder)/*"])@\(ModelPins.whisperKit.revision)"])
        }
    }

    @Test func catalogVariantsPropagateASnapshotFailure() async {
        for (variant, _) in Self.catalogFolders {
            let listed = Seen()
            await #expect(throws: URLError.self) {
                _ = try await WhisperModelFetch.download(
                    variant: variant,
                    listFiles: { _, _ in
                        await listed.record("listed")
                        return []
                    },
                    snapshot: { _, _ in throw URLError(.notConnectedToInternet) }
                )
            }
            #expect(await listed.revisions.isEmpty)
        }
    }

    /// A model folder with Hub's per-file sidecars, in the format `HubApi.writeDownloadMetadata` writes.
    private func makeCache(variant: String, revision: String = ModelPins.whisperKit.revision) throws -> (root: URL, folder: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-cache-\(UUID().uuidString)", isDirectory: true)
        return (root, try Self.writeCache(root: root, variant: variant, revision: revision))
    }

    @discardableResult
    private static func writeCache(root: URL, variant: String, revision: String = ModelPins.whisperKit.revision) throws -> String {
        let folder = try #require(WhisperModelFetch.catalogFolders[variant])
        for file in try #require(ModelPins.whisperKitFiles[variant]) {
            let url = root.appending(path: folder).appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            let sidecar = Self.sidecar(root: root, folder: folder, file: file)
            try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(revision)\n4b37ac79e4370895417e0c9a1b125c39f3943a09\n1791818233.918445\n".write(to: sidecar, atomically: true, encoding: .utf8)
        }
        return folder
    }

    private static func sidecar(root: URL, folder: String, file: String) -> URL {
        root.appending(path: ".cache/huggingface/download").appending(path: folder).appending(path: file + ".metadata")
    }

    /// Resolves `variant` against `root` and reports whether the pinned snapshot had to run. The snapshot stands in for a
    /// real download: it leaves every file and sidecar at the pin.
    private func resolve(variant: String, root: URL) async throws -> (folder: URL, snapshots: [String]) {
        let seen = Seen()
        let folder = try await WhisperModelFetch.download(
            variant: variant,
            cacheRoot: root,
            listFiles: { _, _ in throw URLError(.notConnectedToInternet) },
            snapshot: { globs, revision in
                await seen.record("\(globs)@\(revision)")
                try Self.writeCache(root: root, variant: variant, revision: revision)
                return root
            }
        )
        return (folder, await seen.revisions)
    }

    @Test func pinnedFileListsCoverTheCoreModels() {
        #expect(Set(ModelPins.whisperKitFiles.keys) == Set(WhisperModelFetch.catalogFolders.keys))
        for (variant, files) in ModelPins.whisperKitFiles {
            #expect(Set(files).count == files.count, "\(variant) lists a file twice")
            for model in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
                #expect(files.contains("\(model)/weights/weight.bin"), "\(variant) is missing \(model)")
                #expect(files.contains("\(model)/model.mil"), "\(variant) is missing \(model)")
            }
            #expect(files.contains("config.json"))
        }
        #expect(ModelPins.whisperKitFiles[WhisperEngine.turboVariant]?.count == 24)
        #expect(ModelPins.whisperKitFiles[WhisperEngine.smallEnVariant]?.count == 19)
    }

    @Test func aCompleteCacheAtThePinLoadsWithNoRequest() async throws {
        for (variant, folder) in Self.catalogFolders {
            let (root, _) = try makeCache(variant: variant)
            defer { try? FileManager.default.removeItem(at: root) }
            let resolved = try await WhisperModelFetch.download(
                variant: variant,
                cacheRoot: root,
                listFiles: { _, _ in throw URLError(.notConnectedToInternet) },
                snapshot: { _, _ in throw URLError(.notConnectedToInternet) }
            )
            #expect(resolved == root.appending(path: folder))
        }
    }

    @Test func aMissingFileGoesToThePinnedSnapshot() async throws {
        let (root, folder) = try makeCache(variant: WhisperEngine.smallEnVariant)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appending(path: folder).appending(path: "TextDecoder.mlmodelc/weights/weight.bin"))
        let result = try await resolve(variant: WhisperEngine.smallEnVariant, root: root)
        #expect(result.snapshots == ["\(["\(folder)/*"])@\(ModelPins.whisperKit.revision)"])
        #expect(result.folder == root.appending(path: folder))
    }

    @Test func aSidecarFromAnotherCommitGoesToThePinnedSnapshot() async throws {
        let (root, folder) = try makeCache(variant: WhisperEngine.smallEnVariant)
        defer { try? FileManager.default.removeItem(at: root) }
        try "\(String(repeating: "c", count: 40))\netag\n1791818233.9\n".write(
            to: Self.sidecar(root: root, folder: folder, file: "config.json"), atomically: true, encoding: .utf8)
        #expect(try await resolve(variant: WhisperEngine.smallEnVariant, root: root).snapshots.count == 1)
    }

    @Test func aCacheFromAnOlderPinGoesToThePinnedSnapshot() async throws {
        let (root, _) = try makeCache(variant: WhisperEngine.turboVariant, revision: String(repeating: "c", count: 40))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await resolve(variant: WhisperEngine.turboVariant, root: root).snapshots.count == 1)
    }

    @Test func anOlderCacheTheSnapshotAcceptsOfflineIsNotLoaded() async throws {
        for (variant, _) in Self.catalogFolders {
            let (root, _) = try makeCache(variant: variant, revision: String(repeating: "c", count: 40))
            defer { try? FileManager.default.removeItem(at: root) }
            await #expect(throws: WhisperError.self) {
                _ = try await WhisperModelFetch.download(
                    variant: variant,
                    cacheRoot: root,
                    listFiles: { _, _ in throw URLError(.notConnectedToInternet) },
                    snapshot: { _, _ in root }
                )
            }
        }
    }

    @Test func aSnapshotThatLeavesAFileMissingIsNotLoaded() async throws {
        let (root, folder) = try makeCache(variant: WhisperEngine.smallEnVariant)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appending(path: folder).appending(path: "config.json"))
        await #expect(throws: WhisperError.self) {
            _ = try await WhisperModelFetch.download(
                variant: WhisperEngine.smallEnVariant,
                cacheRoot: root,
                listFiles: { _, _ in [] },
                snapshot: { _, _ in root }
            )
        }
    }

    @Test func aMissingSidecarGoesToThePinnedSnapshot() async throws {
        let (root, folder) = try makeCache(variant: WhisperEngine.smallEnVariant)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: Self.sidecar(root: root, folder: folder, file: "AudioEncoder.mlmodelc/model.mil"))
        #expect(try await resolve(variant: WhisperEngine.smallEnVariant, root: root).snapshots.count == 1)
    }

    @Test func anEmptyCacheGoesToThePinnedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-cache-\(UUID().uuidString)", isDirectory: true)
        #expect(try await resolve(variant: WhisperEngine.turboVariant, root: root).snapshots.count == 1)
    }

    @Test func otherVariantsStillNeedTheListing() async {
        await #expect(throws: URLError.self) {
            _ = try await WhisperModelFetch.download(
                variant: "base.en",
                listFiles: { _, _ in throw URLError(.notConnectedToInternet) },
                snapshot: { _, _ in URL(fileURLWithPath: "/tmp") }
            )
        }
    }
}

@Suite struct WhisperTokenizerPinTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tokenizer-pins-\(UUID().uuidString)", isDirectory: true)
    }

    /// Fake hub content: bytes per file name for a pin, with the pin's digests computed from them.
    private func pin(repo: String = "openai/whisper-test", revision: String = String(repeating: "b", count: 40))
        -> (pin: ModelPins.TokenizerPin, bytes: [String: Data])
    {
        let bytes = ["config.json": Data("{}".utf8), "tokenizer.json": Data("tok".utf8), "tokenizer_config.json": Data("cfg".utf8)]
        return (ModelPins.TokenizerPin(repo: repo, revision: revision, files: bytes.mapValues { WhisperTokenizerFetch.sha256Hex($0) }), bytes)
    }

    @Test func everyTokenizerPinIsACommitWithSHA256Digests() {
        for pin in ModelPins.whisperTokenizers.values {
            #expect(pin.revision.count == 40 && pin.revision.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase })
            #expect(Set(pin.files.keys) == ["config.json", "tokenizer.json", "tokenizer_config.json"])
            for digest in pin.files.values { #expect(digest.count == 64 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }) }
        }
    }

    @Test func eachShippedVariantMapsToItsOwnTokenizerRepo() {
        #expect(ModelPins.whisperTokenizers[WhisperEngine.turboVariant]?.repo == "openai/whisper-large-v3")
        #expect(ModelPins.whisperTokenizers[WhisperEngine.smallEnVariant]?.repo == "openai/whisper-small.en")
    }

    @Test func fetchesAtTheExactPinnedRevisionForEachVariant() async {
        for variant in [WhisperEngine.turboVariant, WhisperEngine.smallEnVariant] {
            let expected = ModelPins.whisperTokenizers[variant]!
            let seen = Seen()
            let root = makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try? await WhisperTokenizerFetch.prepare(
                variant: variant, root: root, legacyFolders: [],
                fetch: { repo, revision, file in
                    await seen.record("\(repo)@\(revision)/\(file)")
                    throw URLError(.notConnectedToInternet)
                })
            #expect(await seen.revisions == ["\(expected.repo)@\(expected.revision)/config.json"])
        }
    }

    @Test func propagatesRepoAndRevisionToEveryRequest() async throws {
        let (pin, bytes) = pin()
        let seen = Seen()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root,
            fetch: { repo, revision, file in
                await seen.record("\(repo)@\(revision)/\(file)")
                return bytes[file]!
            })
        let prefix = "openai/whisper-test@\(String(repeating: "b", count: 40))/"
        #expect(await seen.revisions.sorted() == bytes.keys.sorted().map { prefix + $0 })
        #expect(folder.lastPathComponent == pin.revision)
        for (name, data) in bytes { #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data) }
    }

    @Test func aVerifiedCacheMakesNoRequests() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, file in bytes[file]! })
        let seen = Seen()
        _ = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root,
            fetch: { _, _, file in
                await seen.record(file)
                return bytes[file]!
            })
        #expect(await seen.revisions.isEmpty)
    }

    @Test func aVerifiedCacheLoadsOffline() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, file in bytes[file]! })
        let offline = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        #expect(offline == cached)
    }

    private func legacyFolder(_ files: [String: Data]) throws -> URL {
        let folder = makeRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    @Test func matchingLegacyFilesAreAdoptedWithNoRequest() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        let legacy = try legacyFolder(bytes)
        defer { for url in [root, legacy] { try? FileManager.default.removeItem(at: url) } }
        let seen = Seen()
        let folder = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root, legacyFolders: [legacy],
            fetch: { _, _, file in
                await seen.record(file)
                throw URLError(.notConnectedToInternet)
            })
        #expect(await seen.revisions.isEmpty)
        for (name, data) in bytes {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data)
            #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(name).path), "the legacy copy stays")
        }
    }

    @Test func aMismatchedLegacyFileIsIgnoredAndFetchedFromThePinnedCommit() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        var altered = bytes
        altered["tokenizer.json"] = Data("old main revision".utf8)
        let legacy = try legacyFolder(altered)
        defer { for url in [root, legacy] { try? FileManager.default.removeItem(at: url) } }
        let seen = Seen()
        let folder = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root, legacyFolders: [legacy],
            fetch: { _, _, file in
                await seen.record(file)
                return bytes[file]!
            })
        #expect(await seen.revisions == ["tokenizer.json"])
        for (name, data) in bytes { #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data) }
    }

    @Test func aMismatchedLegacyFileFailsClosedOffline() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        var altered = bytes
        altered["config.json"] = Data("not the pinned bytes".utf8)
        let legacy = try legacyFolder(altered)
        defer { for url in [root, legacy] { try? FileManager.default.removeItem(at: url) } }
        await #expect(throws: URLError.self) {
            _ = try await WhisperTokenizerFetch.prepare(
                pin: pin, root: root, legacyFolders: [legacy], fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(pin.repo)/\(pin.revision)/config.json").path))
    }

    @Test func aLaterLegacyFolderSuppliesWhatAnEarlierOneLacks() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        let first = try legacyFolder(["config.json": Data("wrong".utf8)])
        let second = try legacyFolder(bytes)
        defer { for url in [root, first, second] { try? FileManager.default.removeItem(at: url) } }
        let folder = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root, legacyFolders: [first, second], fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        for (name, data) in bytes { #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data) }
    }

    @Test func noLegacyFilesStillFetchEverything() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        let legacy = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        _ = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root, legacyFolders: [legacy],
            fetch: { _, _, file in
                await seen.record(file)
                return bytes[file]!
            })
        #expect(await seen.revisions.sorted() == bytes.keys.sorted())
    }

    @Test func legacyFoldersCoverTheHubCacheAndTheModelFolder() {
        let paths = WhisperTokenizerFetch.legacyFolders(repo: "openai/whisper-large-v3", variant: "large-v3-v20240930_turbo").map(\.path)
        #expect(paths.count == 3)
        #expect(paths[0].hasSuffix("/huggingface/models/openai/whisper-large-v3"))
        #expect(paths[1].hasSuffix("/huggingface/models/\(ModelPins.whisperKit.repo)/openai_whisper-large-v3-v20240930_turbo"))
        #expect(paths[2] == paths[1] + "/models/openai/whisper-large-v3")
    }

    @Test func anAlteredCachedFileIsReplacedFromThePinnedCommit() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, file in bytes[file]! })
        try Data("evil".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        let seen = Seen()
        _ = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root,
            fetch: { _, _, file in
                await seen.record(file)
                return bytes[file]!
            })
        #expect(await seen.revisions == ["tokenizer.json"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("tokenizer.json")) == bytes["tokenizer.json"])
    }

    @Test func aMissingCachedFileIsRefetchedAndAnUnpinnedChatTemplateIsRemoved() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, file in bytes[file]! })
        try FileManager.default.removeItem(at: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("chat_template.json"))
        let seen = Seen()
        _ = try await WhisperTokenizerFetch.prepare(
            pin: pin, root: root,
            fetch: { _, _, file in
                await seen.record(file)
                return bytes[file]!
            })
        #expect(await seen.revisions == ["config.json"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("chat_template.json").path))
    }

    @Test func concurrentPreparationOfTheSameUncachedVariantSucceeds() async throws {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetch: WhisperTokenizerFetch.FetchFile = { _, _, file in
            try await Task.sleep(nanoseconds: 50_000_000)
            return bytes[file]!
        }
        let folders = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                group.addTask { try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: fetch) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(Set(folders).count == 1)
        for (name, data) in bytes {
            #expect(try Data(contentsOf: folders[0].appendingPathComponent(name)) == data)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders[0].path).sorted() == bytes.keys.sorted())
    }

    @Test func downloadedBytesThatMissTheDigestFailLoudly() async {
        let (pin, _) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, _ in Data("tampered".utf8) })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("openai/whisper-test/\(pin.revision)/tokenizer.json").path))
    }

    @Test func aFailedFetchFailsInsteadOfFallingBack() async {
        let (pin, _) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        }
    }

    @Test func aBranchNameIsNotAcceptedAsARevision() async {
        let (pin, bytes) = pin(revision: "main")
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await WhisperTokenizerFetch.prepare(pin: pin, root: root, fetch: { _, _, file in bytes[file]! })
        }
    }

    @Test func anUnknownVariantHasNoTokenizer() async {
        await #expect(throws: (any Error).self) {
            _ = try await WhisperTokenizerFetch.prepare(variant: "tiny", root: makeRoot(), fetch: { _, _, _ in Data() })
        }
    }

    @Test func aFolderThatVerifiesButDoesNotParseStopsBeforeWhisperKit() async {
        let (pin, bytes) = pin()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The digests match, but the content isn't a tokenizer, so the engine's own parse must reject it.
        await #expect(throws: (any Error).self) {
            _ = try await WhisperEngine.verifiedTokenizerFolder(
                variant: "test", pins: ["test": pin], root: root, fetch: { _, _, file in bytes[file]! })
        }
    }
}

private actor Seen {
    private(set) var revisions: [String] = []
    func record(_ revision: String) { revisions.append(revision) }
}
