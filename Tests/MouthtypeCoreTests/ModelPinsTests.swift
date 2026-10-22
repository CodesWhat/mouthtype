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
            variant: "small.en",
            listFiles: { globs, revision in
                await seen.record(revision)
                #expect(globs == ["*small.en/*"])
                return ["openai_whisper-small.en/config.json", "openai_whisper-small.en/AudioEncoder.mlmodelc/model.mil"]
            },
            snapshot: { _, revision in
                await seen.record(revision)
                return URL(fileURLWithPath: "/tmp/models/argmaxinc/whisperkit-coreml")
            }
        )
        #expect(await seen.revisions == [ModelPins.whisperKit.revision, ModelPins.whisperKit.revision])
        #expect(folder.lastPathComponent == "openai_whisper-small.en")
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
}

private actor Seen {
    private(set) var revisions: [String] = []
    func record(_ revision: String) { revisions.append(revision) }
}
