import CryptoKit
import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct ModelCacheAdoptionTests {
    private let pin = ModelPins.Pin(repo: "owner/model", revision: String(repeating: "c", count: 40))
    private let weights = Data("compiled model weights".utf8)
    private let config = Data("{\"a\":1}".utf8)

    private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func gitBlobID(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hex(hasher.finalize())
    }

    /// An LFS weights file inside a bundle and a plain root file.
    private var manifest: ModelCacheAdoption.Manifest {
        ModelCacheAdoption.Manifest(schema: 1, repos: [pin.repo: .init(revision: pin.revision, files: [
            .init(path: "Model.mlmodelc/weights/weight.bin", size: weights.count, sha256: hex(SHA256.hash(data: weights)), blob: nil),
            .init(path: "config.json", size: config.count, sha256: nil, blob: gitBlobID(config)),
        ])])
    }

    private func makeCache() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
        let weightsDir = folder.appendingPathComponent("Model.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        try weights.write(to: weightsDir.appendingPathComponent("weight.bin"))
        try config.write(to: folder.appendingPathComponent("config.json"))
        return folder
    }

    private func marker(_ folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(ModelCacheAdoption.markerName), encoding: .utf8)
    }

    @Test func completeCacheIsAdoptedWithoutAnyNetworkAndGetsFluidAudiosMarker() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        // adopt takes no network dependency at all, so this is the offline first launch.
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .adopted)
        #expect(marker(folder) == pin.revision + "\n")
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .hasMarker)
    }

    @Test func extraFilesFluidAudioNeverLoadsDoNotBlockAdoption() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("other".utf8).write(to: folder.appendingPathComponent("stray.bin"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .adopted)
    }

    @Test func aMissingListedFileDoesNotAdopt() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Model.mlmodelc/weights/weight.bin"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .incomplete)
        #expect(marker(folder) == nil)
    }

    @Test func aChangedFileDoesNotAdopt() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Same size, different content, for both the LFS and the plain file.
        try Data("compiled model weightz".utf8).write(to: folder.appendingPathComponent("Model.mlmodelc/weights/weight.bin"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .incomplete)
        try weights.write(to: folder.appendingPathComponent("Model.mlmodelc/weights/weight.bin"))
        try Data("{\"a\":2}".utf8).write(to: folder.appendingPathComponent("config.json"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .incomplete)
        #expect(marker(folder) == nil)
    }

    @Test func aLeftoverPartialFileDoesNotAdopt() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("half".utf8).write(to: folder.appendingPathComponent("Model.mlmodelc/weights/other.bin.partial"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder, manifest: manifest) == .incomplete)
        #expect(marker(folder) == nil)
    }

    @Test func aManifestForAnotherRevisionDoesNotAdopt() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = ModelPins.Pin(repo: pin.repo, revision: String(repeating: "d", count: 40))
        #expect(await ModelCacheAdoption.adopt(other, folder: folder, manifest: manifest) == .noManifest)
        #expect(marker(folder) == nil)
    }

    @Test func noCacheMeansNothingToAdopt() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)")
        #expect(await ModelCacheAdoption.adopt(pin, folder: missing, manifest: manifest) == .noCache)
    }

    @Test func gitBlobIDMatchesGitsOwnVector() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString)")
        try Data("hello\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ModelCacheAdoption.gitBlobSHA1Hex(url) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func bundledManifestCoversEveryFluidAudioPinAtItsRevision() throws {
        let manifest = try #require(ModelCacheAdoption.bundledManifest)
        let required: [(ModelPins.Pin, [String])] = [
            (ModelPins.parakeetV3, ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]),
            (ModelPins.parakeetV2, ["Preprocessor", "Encoder", "Decoder", "JointDecision"]),
            (ModelPins.ctc110m, ["MelSpectrogram", "AudioEncoder"]),
            (ModelPins.sileroVAD, ["silero-vad-unified-256ms-v6.2.1"]),
        ]
        for (pin, bundles) in required {
            let entry = try #require(manifest.repos[pin.repo], "no manifest entry for \(pin.repo)")
            #expect(entry.revision == pin.revision, "\(pin.repo) manifest is at \(entry.revision)")
            for bundle in bundles {
                #expect(entry.files.contains { $0.path.hasPrefix(bundle + ".mlmodelc/") }, "\(pin.repo) lacks \(bundle)")
            }
            #expect(entry.files.allSatisfy { ($0.sha256?.count == 64) != ($0.blob?.count == 40) })
        }
    }
}
