import AppKit
import Foundation
import SwiftUI

/// One HTTP response for a favicon lookup. `truncated` means the body hit the size cap.
struct FaviconResponse: Sendable {
    let data: Data
    let url: URL
    let truncated: Bool
}

/// Finds icon links in a page's HTML and ranks them. Pure, so it is tested without a network.
enum FaviconLinks {
    private static let targetSize = 64

    /// Candidate icon URLs for `base`, best first: sizes nearest 64px lead, a scalable icon counts as 64, and an icon with no declared size
    /// counts as 32. Only https links on the site's own host (or a sibling subdomain of it) are kept.
    static func candidates(html: String, base: URL) -> [URL] {
        guard let baseHost = base.host?.lowercased() else { return [] }
        var ranked: [(url: URL, score: Int, order: Int)] = []
        var seen = Set<String>()
        for (order, tag) in linkTags(in: html).enumerated() {
            let attributes = parseAttributes(tag)
            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") else { continue }
            guard let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
                let url = URL(string: href, relativeTo: base)?.absoluteURL,
                url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), sameSite(host, baseHost),
                seen.insert(url.absoluteString).inserted
            else { continue }
            ranked.append((url, score(sizes: attributes["sizes"], type: attributes["type"], path: url.path), order))
        }
        return ranked.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.url)
    }

    static func sameSite(_ host: String, _ other: String) -> Bool {
        if host == other { return true }
        func root(_ value: String) -> String { value.split(separator: ".").suffix(2).joined(separator: ".") }
        return root(host) == root(other)
    }

    private static func score(sizes: String?, type: String?, path: String) -> Int {
        let tokens = (sizes ?? "").lowercased().split(whereSeparator: \.isWhitespace)
        if tokens.contains("any") || type?.lowercased() == "image/svg+xml" || path.lowercased().hasSuffix(".svg") { return 0 }
        let dimensions = tokens.compactMap { token -> Int? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return min(width, height)
        }
        guard !dimensions.isEmpty else { return abs(32 - targetSize) }
        return dimensions.map { abs($0 - targetSize) }.min() ?? 0
    }

    private static func linkTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z_:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))") else { return [:] }
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).compactMap { Range(match.range(at: $0), in: tag).map { String(tag[$0]) } }.first ?? ""
            let name = tag[nameRange].lowercased()
            if result[name] == nil { result[name] = value }
        }
        return result
    }
}

/// Fetches a site's own favicon and keeps it on disk. The only request goes to the site itself: its home page, the icon its page names,
/// and `/favicon.ico` as a fallback. No third-party icon service, no cookies, no retries on render.
actor SiteFaviconStore {
    static let shared = SiteFaviconStore()

    static let maxBytes = 256 * 1024
    static let positiveTTL: TimeInterval = 30 * 24 * 3600
    static let negativeTTL: TimeInterval = 24 * 3600
    private static let maxCandidates = 4

    typealias Fetch = @Sendable (URL) async throws -> FaviconResponse

    private let directory: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(directory: URL = SiteFaviconStore.defaultDirectory, fetch: @escaping Fetch = SiteFaviconStore.liveFetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.fetch = fetch
        self.now = now
    }

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Mouthtype", isDirectory: true).appendingPathComponent("SiteFavicons", isDirectory: true)
    }

    static var runningUnderTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["SWT_EXPERIMENTAL_EVENT_STREAM_OUTPUT"] != nil || NSClassFromString("XCTestCase") != nil
            || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    /// A lowercase hostname that is safe to put in a path and worth a request, or nil.
    static func normalizedHost(_ domain: String) -> String? {
        let host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.contains("."), host.count <= 253, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
            !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."), host.split(separator: ".").last?.allSatisfy(\.isNumber) == false
        else { return nil }
        return host
    }

    /// The cached icon if the disk has a fresh one. Never touches the network.
    nonisolated func cachedImage(for domain: String) -> NSImage? {
        guard let host = Self.normalizedHost(domain), let data = try? Data(contentsOf: iconURL(host)), isFresh(iconURL(host), ttl: Self.positiveTTL) else { return nil }
        return Self.image(from: data)
    }

    /// The icon for a site: from disk when fresh, else fetched once. A recent failure returns nil without a request.
    func image(for domain: String) async -> NSImage? {
        guard let host = Self.normalizedHost(domain) else { return nil }
        if let cached = cachedImage(for: host) { return cached }
        if isFresh(missURL(host), ttl: Self.negativeTTL) { return nil }
        if let task = inFlight[host] { return await task.value }
        let task = Task { await self.load(host) }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil
        return result
    }

    private func load(_ host: String) async -> NSImage? {
        let home = URL(string: "https://\(host)/")
        var urls: [URL] = []
        if let home, let page = try? await fetch(home) {
            let html = String(decoding: page.data, as: UTF8.self)
            urls = FaviconLinks.candidates(html: html, base: page.url)
        }
        if let fallback = URL(string: "https://\(host)/favicon.ico"), !urls.contains(fallback) { urls.append(fallback) }
        for url in urls.prefix(Self.maxCandidates + 1) {
            guard let response = try? await fetch(url), !response.truncated, !response.data.isEmpty, response.data.count <= Self.maxBytes,
                let image = Self.image(from: response.data)
            else { continue }
            write(response.data, to: iconURL(host))
            try? FileManager.default.removeItem(at: missURL(host))
            return image
        }
        write(Data(), to: missURL(host))
        return nil
    }

    static func image(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0, !image.representations.isEmpty else { return nil }
        return image
    }

    private nonisolated func iconURL(_ host: String) -> URL { directory.appendingPathComponent(host + ".icon") }
    private nonisolated func missURL(_ host: String) -> URL { directory.appendingPathComponent(host + ".miss") }

    private nonisolated func isFresh(_ url: URL, ttl: TimeInterval) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return now().timeIntervalSince(modified) < ttl
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
    }

    // MARK: Network

    /// Ephemeral session (no cookies or credential store), 5 second timeout, plain User-Agent, at most 5 https redirects, body capped.
    @Sendable static func liveFetch(_ url: URL) async throws -> FaviconResponse {
        // A test that reaches here forgot to inject a store. Fail loudly instead of hitting the network and the real cache.
        precondition(!runningUnderTests, "SiteFaviconStore.liveFetch ran under a test. Inject a store with a temp directory and a fake fetch.")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectLimit(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mouthtype", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        var data = Data()
        var truncated = false
        for try await byte in bytes {
            if data.count >= maxBytes { truncated = true; break }
            data.append(byte)
        }
        return FaviconResponse(data: data, url: http.url ?? url, truncated: truncated)
    }

    private final class RedirectLimit: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private var count = 0

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            count += 1
            completionHandler(count <= 5 && request.url?.scheme == "https" ? request : nil)
        }
    }
}

private struct SiteFaviconStoreKey: EnvironmentKey {
    static var defaultValue: SiteFaviconStore { SiteFaviconStore.shared }
}

extension EnvironmentValues {
    /// The favicon store site rows read. The app uses the shared one; tests inject a temp directory and a fake fetch.
    var siteFavicons: SiteFaviconStore {
        get { self[SiteFaviconStoreKey.self] }
        set { self[SiteFaviconStoreKey.self] = newValue }
    }
}
