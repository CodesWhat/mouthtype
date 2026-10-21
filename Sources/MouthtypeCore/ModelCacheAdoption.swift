import CryptoKit
import FluidAudio
import Foundation

/// FluidAudio keys its cache on a revision marker. A cache made before the pins has none, and FluidAudio only
/// adopts one by fetching the pinned tree listing, which fails on a first launch with no network. This verifies
/// such a cache against a manifest bundled with the app and writes the marker itself.
///
/// Anything short of a complete, matching cache is left untouched for FluidAudio's own adoption or download.
enum ModelCacheAdoption {
    enum Outcome: Equatable, Sendable {
        case adopted
        /// The folder already has a marker, so FluidAudio decides what to do with it.
        case hasMarker
        case noCache
        /// A required file is missing, differs, or a `.partial` download is left behind.
        case incomplete
        /// The bundled manifest has no entry for this pin's repo and revision.
        case noManifest
    }

    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let size: Int
            let sha256: String?
            let blob: String?
        }

        struct Repo: Decodable, Sendable {
            let revision: String
            let files: [File]
        }

        let schema: Int
        let repos: [String: Repo]
    }

    /// FluidAudio's own marker file name and content format (`<revision>\n`).
    static let markerName = ".fluidaudio-revision"

    static let bundledManifest: Manifest? = {
        guard let url = Bundle.module.url(forResource: "ModelManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    /// Hashing happens at most once per cache: a match writes the marker, which ends adoption. Sizes and presence are
    /// checked first, so a cache that can't match is rejected without reading its weights.
    static func adopt(_ pin: ModelPins.Pin, folder: URL, manifest: Manifest? = bundledManifest) async -> Outcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .noCache }
        let marker = folder.appendingPathComponent(markerName)
        if fm.fileExists(atPath: marker.path) { return .hasMarker }
        guard let entry = manifest?.repos[pin.repo], entry.revision == pin.revision, !entry.files.isEmpty else { return .noManifest }

        let complete = await Task.detached(priority: .utility) { verify(folder: folder, files: entry.files) }.value
        guard complete else { return .incomplete }
        do {
            try Data((pin.revision + "\n").utf8).write(to: marker, options: .atomic)
        } catch {
            return .incomplete
        }
        return .adopted
    }

    /// Every manifest file must be present with its recorded size and content id, and no `.partial` files may remain.
    /// Files outside the manifest are ignored; FluidAudio never loads them.
    static func verify(folder: URL, files: [Manifest.File]) -> Bool {
        guard !hasPartialFiles(in: folder) else { return false }
        var present: [(URL, Manifest.File)] = []
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileSize(url) == file.size
            else { return false }
            present.append((url, file))
        }
        for (url, file) in present {
            let digest: String?
            if let sha256 = file.sha256 {
                digest = sha256Hex(url) == sha256 ? sha256 : nil
            } else if let blob = file.blob {
                digest = gitBlobSHA1Hex(url) == blob ? blob : nil
            } else {
                digest = nil
            }
            guard digest != nil else { return false }
        }
        return true
    }

    private static func hasPartialFiles(in folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".partial") || url.lastPathComponent.hasSuffix(".partial.etag") {
            return true
        }
        return false
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    static func sha256Hex(_ url: URL) -> String? {
        var hasher = SHA256()
        guard stream(url, { hasher.update(data: $0) }) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Git's object id for a file: SHA-1 over `blob <size>\0` and the content. The Hub lists it for plain, non-LFS files.
    static func gitBlobSHA1Hex(_ url: URL) -> String? {
        guard let size = fileSize(url) else { return nil }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        guard stream(url, { hasher.update(data: $0) }) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stream(_ url: URL, _ consume: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return true }
                consume(chunk)
            } catch {
                return false
            }
        }
    }

    // MARK: - Live wiring

    /// FluidAudio's default models directory for `repo`.
    static func cacheFolder(for repo: Repo) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(repo.folderName, isDirectory: true)
    }

    @discardableResult
    static func adoptCache(of repo: Repo, pin: ModelPins.Pin) async -> Outcome {
        await adopt(pin, folder: cacheFolder(for: repo))
    }
}
