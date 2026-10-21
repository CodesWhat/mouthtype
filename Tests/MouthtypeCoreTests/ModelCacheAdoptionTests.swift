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

    /// A tree listing with an LFS file, a plain file, and one file the cache doesn't hold.
    private func tree(weightsSHA: String? = nil) -> Data {
        let sha = weightsSHA ?? hex(SHA256.hash(data: weights))
        let json = """
        [{"type":"directory","oid":"d","size":0,"path":"Model.mlmodelc"},
         {"type":"file","oid":"x","size":\(weights.count),"lfs":{"oid":"\(sha)","size":\(weights.count)},"path":"Model.mlmodelc/weights/weight.bin"},
         {"type":"file","oid":"\(gitBlobID(config))","size":\(config.count),"path":"config.json"},
         {"type":"file","oid":"y","size":5,"lfs":{"oid":"\(String(repeating: "0", count: 64))","size":5},"path":"NotDownloaded.mlpackage/Data/other.bin"}]
        """
        return Data(json.utf8)
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

    @Test func matchingCacheIsAdoptedAndGetsFluidAudiosMarker() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let requested = Requested()
        let outcome = await ModelCacheAdoption.adopt(pin, folder: folder) { repo, revision in
            await requested.record("\(repo)@\(revision)")
            return tree()
        }
        #expect(outcome == .adopted)
        #expect(marker(folder) == pin.revision + "\n")
        #expect(await requested.values == ["owner/model@\(pin.revision)"])

        // A second launch sees the marker and never asks the Hub or rehashes.
        let again = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in
            Issue.record("fetched the tree for an adopted cache")
            return Data()
        }
        #expect(again == .hasMarker)
    }

    @Test func aChangedFileIsAMismatchAndLeavesNoMarker() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in tree(weightsSHA: String(repeating: "1", count: 64)) }
        #expect(outcome == .mismatch)
        #expect(marker(folder) == nil)
    }

    @Test func aSameSizeEditToAPlainFileIsAMismatch() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{\"a\":2}".utf8).write(to: folder.appendingPathComponent("config.json"))
        let outcome = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in tree() }
        #expect(outcome == .mismatch)
    }

    @Test func aLocalFileMissingFromTheListingIsAMismatch() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("extra".utf8).write(to: folder.appendingPathComponent("stray.bin"))
        #expect(await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in tree() } == .mismatch)
    }

    @Test func anUnreachableHubKeepsTheCacheAndRetriesNextLaunch() async throws {
        let folder = try makeCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let offline = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(offline == .unreachable)
        #expect(marker(folder) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path))

        let garbled = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in Data("<html>".utf8) }
        #expect(garbled == .unreachable)

        let online = await ModelCacheAdoption.adopt(pin, folder: folder) { _, _ in tree() }
        #expect(online == .adopted)
    }

    @Test func noCacheMeansNothingToAdopt() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)")
        let outcome = await ModelCacheAdoption.adopt(pin, folder: missing) { _, _ in
            Issue.record("fetched the tree with no cache")
            return Data()
        }
        #expect(outcome == .noCache)
    }

    @Test func nextPageComesFromTheLinkHeader() {
        let link = "<https://huggingface.co/api/models/o/m/tree/abc?recursive=1&cursor=x>; rel=\"next\""
        #expect(ModelCacheAdoption.nextPageURL(link)?.absoluteString == "https://huggingface.co/api/models/o/m/tree/abc?recursive=1&cursor=x")
        #expect(ModelCacheAdoption.nextPageURL(nil) == nil)
        #expect(ModelCacheAdoption.nextPageURL("<https://x>; rel=\"prev\"") == nil)
    }
}

private actor Requested {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
