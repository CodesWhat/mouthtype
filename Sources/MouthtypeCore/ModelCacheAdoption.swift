import CryptoKit
import FluidAudio
import Foundation

/// FluidAudio treats a cache with no revision marker as stale as soon as a pin is set, and deletes it. Caches made
/// before the pins were added are almost always the pinned commit already, so this verifies them against the pinned
/// revision's file listing on the Hub and writes the marker instead of letting FluidAudio re-download.
enum ModelCacheAdoption {
    enum Outcome: Equatable, Sendable {
        case adopted
        /// The folder already has a marker, so FluidAudio decides what to do with it.
        case hasMarker
        case noCache
        /// A local file differs from the pinned revision. FluidAudio's normal re-download handles it.
        case mismatch
        /// The listing couldn't be fetched or read. The cache stays as it is and adoption retries on the next launch.
        case unreachable
    }

    typealias FetchTree = @Sendable (_ repo: String, _ revision: String) async throws -> Data

    /// FluidAudio's own marker file name and content format (`<revision>\n`).
    static let markerName = ".fluidaudio-revision"

    struct Entry: Decodable, Sendable {
        struct LFS: Decodable, Sendable { let oid: String }
        let type: String
        let oid: String
        let size: Int
        let path: String
        let lfs: LFS?
    }

    /// Hashes happen once: a match writes the marker, which ends adoption, and a mismatch hands the folder to
    /// FluidAudio, which replaces it. An unreachable Hub fails before any file is read.
    static func adopt(_ pin: ModelPins.Pin, folder: URL, fetchTree: FetchTree) async -> Outcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .noCache }
        let marker = folder.appendingPathComponent(markerName)
        if fm.fileExists(atPath: marker.path) { return .hasMarker }
        guard !localFiles(in: folder).isEmpty else { return .noCache }

        let entries: [String: Entry]
        do {
            let data = try await fetchTree(pin.repo, pin.revision)
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            entries = Dictionary(decoded.filter { $0.type == "file" }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            return .unreachable
        }
        guard !entries.isEmpty else { return .unreachable }

        let matches = await Task.detached(priority: .utility) { verify(folder: folder, against: entries) }.value
        guard matches else { return .mismatch }
        do {
            try Data((pin.revision + "\n").utf8).write(to: marker, options: .atomic)
        } catch {
            return .unreachable
        }
        return .adopted
    }

    /// Every local file must be in the pinned listing with the same size and content hash. The listing may hold
    /// more files than the cache, since FluidAudio only downloads the compiled models it needs.
    static func verify(folder: URL, against entries: [String: Entry]) -> Bool {
        let files = localFiles(in: folder)
        guard !files.isEmpty else { return false }
        for (relative, url) in files {
            guard let entry = entries[relative], let size = fileSize(url), size == entry.size else { return false }
            let digest = entry.lfs.map { _ in sha256Hex(url) } ?? gitBlobSHA1Hex(url, size: size)
            guard let digest, digest == (entry.lfs?.oid ?? entry.oid) else { return false }
        }
        return true
    }

    private static func localFiles(in folder: URL) -> [String: URL] {
        let root = folder.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: URL] = [:]
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            result[String(path.dropFirst(prefix.count))] = url
        }
        return result
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func sha256Hex(_ url: URL) -> String? {
        var hasher = SHA256()
        guard stream(url, { hasher.update(data: $0) }) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Git's object id for a file: SHA-1 over `blob <size>\0` and the content. Used for small files the Hub doesn't list an LFS hash for.
    private static func gitBlobSHA1Hex(_ url: URL, size: Int) -> String? {
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
        await adopt(pin, folder: cacheFolder(for: repo), fetchTree: fetchTreeFromHub)
    }

    /// The recursive tree listing at a commit, following the Hub's `Link: rel="next"` pages into one JSON array.
    static let fetchTreeFromHub: FetchTree = { repo, revision in
        var components = URLComponents(url: try ModelRegistry.apiModels(repo, "tree/\(revision)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        var next = components?.url
        var merged: [Any] = []
        var pages = 0
        while let url = next, pages < 50 {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let page = try JSONSerialization.jsonObject(with: data) as? [Any]
            else { throw URLError(.badServerResponse) }
            merged += page
            next = nextPageURL(http.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        if next != nil { throw URLError(.dataLengthExceedsMaximum) }
        return try JSONSerialization.data(withJSONObject: merged)
    }

    static func nextPageURL(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }
}
