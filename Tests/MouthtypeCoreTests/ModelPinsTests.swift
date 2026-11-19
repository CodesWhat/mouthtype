import FluidAudio
import Foundation
import Testing
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
                variant: variant, root: root,
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
