import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MouthtypeMac

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func add(_ url: URL) { lock.lock(); urls.append(url.absoluteString); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}

private func png() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("favicon-tests-\(UUID().uuidString)", isDirectory: true)
}

private func store(
    _ directory: URL, calls: Calls, now: @escaping @Sendable () -> Date = { Date() }, handler: @escaping @Sendable (URL) -> FaviconResponse?
) -> SiteFaviconStore {
    SiteFaviconStore(
        directory: directory,
        fetch: { url in
            calls.add(url)
            guard let response = handler(url) else { throw URLError(.cannotFindHost) }
            return response
        }, now: now)
}

@Suite struct FaviconLinksTests {
    let base = URL(string: "https://www.example.com/app/")!

    @Test func resolvesRelativeAndAbsoluteLinks() {
        let html = """
            <html><head>
            <link rel="icon" href="/favicon-32.png" sizes="32x32">
            <link rel='shortcut icon' href='img/small.ico'>
            <link rel="apple-touch-icon" href="https://www.example.com/touch.png">
            </head></html>
            """
        let urls = FaviconLinks.candidates(html: html, base: base).map(\.absoluteString)
        #expect(urls.contains("https://www.example.com/favicon-32.png"))
        #expect(urls.contains("https://www.example.com/app/img/small.ico"))
        #expect(urls.contains("https://www.example.com/touch.png"))
    }

    @Test func prefersSizeNearest64() {
        let html = """
            <link rel="icon" href="/16.png" sizes="16x16">
            <link rel="icon" href="/180.png" sizes="180x180">
            <link rel="icon" href="/48.png" sizes="48x48">
            <link rel="icon" href="/64.png" sizes="32x32 64x64">
            """
        #expect(FaviconLinks.candidates(html: html, base: base).map(\.lastPathComponent) == ["64.png", "48.png", "16.png", "180.png"])
    }

    @Test func ignoresMissingAndUnrelatedLinks() {
        #expect(FaviconLinks.candidates(html: "<html><head><title>x</title></head></html>", base: base).isEmpty)
        let html = """
            <link rel="stylesheet" href="/a.css"><link rel="mask-icon" href="/mask.svg"><link rel="icon">
            <link rel="icon" href="http://www.example.com/insecure.png">
            """
        #expect(FaviconLinks.candidates(html: html, base: base).isEmpty)
    }

    @Test func keepsOnlyTheSitesOwnHosts() {
        let html = """
            <link rel="icon" href="https://cdn.example.com/ok.png">
            <link rel="icon" href="https://tracker.other.net/bad.png">
            """
        #expect(FaviconLinks.candidates(html: html, base: base).map(\.host) == ["cdn.example.com"])
    }
}

@Suite struct FaviconRedirectTests {
    private func allows(_ from: String, _ to: String) -> Bool {
        SiteFaviconStore.allowsRedirect(from: URL(string: from), to: URL(string: to))
    }

    @Test func refusesRedirectsToOtherHosts() {
        #expect(!allows("https://example.com/", "https://evil.net/"))
        #expect(!allows("https://example.com/", "https://notexample.com/"))
        #expect(!allows("https://example.com/", "https://example.com.evil.net/"))
        #expect(!allows("https://a.co.uk/", "https://b.co.uk/"))
        #expect(!allows("https://a.github.io/", "https://b.github.io/"))
    }

    @Test func keepsSameSiteHttpsRedirects() {
        #expect(allows("https://example.com/", "https://example.com/home"))
        #expect(allows("https://example.com/", "https://www.example.com/"))
        #expect(allows("https://www.example.com/", "https://example.com/"))
        #expect(!allows("https://example.com/", "http://example.com/"))
    }

    @Test func siblingIconHostsAreNotAccepted() {
        let base = URL(string: "https://a.co.uk/")!
        let html = #"<link rel="icon" href="https://b.co.uk/x.png"><link rel="icon" href="https://cdn.a.co.uk/y.png">"#
        #expect(FaviconLinks.candidates(html: html, base: base).map(\.host) == ["cdn.a.co.uk"])
    }

    @Test func delegateCancelsOffSiteRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: URL(string: "https://example.com/")!))
        let response = HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let delegate = SiteFaviconStore.RedirectLimit()
        var results: [URLRequest?] = []
        for target in ["https://evil.net/", "https://www.example.com/"] {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { results.append($0) }
        }
        #expect(results[0] == nil)
        #expect(results[1]?.url?.host == "www.example.com")
    }
}

@Suite(.serialized) @MainActor struct StyleMemberIconFetchTests {
    private func fetches(for members: [StyleMember]) async -> [String] {
        let calls = Calls()
        let store = store(tempDirectory(), calls: calls) { _ in nil }
        for member in members {
            let host = NSHostingView(rootView: StyleMemberIcon(member: member).environment(\.siteFavicons, store))
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            withExtendedLifetime(window) {}
        }
        return calls.all
    }

    @Test func builtInSiteMembersMakeNoRequests() async {
        let builtIns = StyleContextID.allCases.flatMap { StyleContexts.builtIns($0) }.filter { $0.kind == .site }
        #expect(builtIns.count >= 4)
        #expect(builtIns.allSatisfy { !StyleMemberIcon.fetchesFavicon(for: $0) })
        #expect(await fetches(for: builtIns).isEmpty)
    }

    @Test func addedSiteMembersStillFetch() async {
        let added = StyleMember(kind: .site, name: "example.com", keys: ["example.com"], isBuiltIn: false)
        #expect(StyleMemberIcon.fetchesFavicon(for: added))
        #expect(await fetches(for: [added]).first == "https://example.com/")
    }
}

@Suite struct SiteFaviconStoreTests {
    @Test func rejectsUnsafeHosts() {
        #expect(SiteFaviconStore.normalizedHost("LinkedIn.com") == "linkedin.com")
        #expect(SiteFaviconStore.normalizedHost("localhost") == nil)
        #expect(SiteFaviconStore.normalizedHost("../etc") == nil)
        #expect(SiteFaviconStore.normalizedHost("a/b.com") == nil)
        #expect(SiteFaviconStore.normalizedHost("10.0.0.1") == nil)
    }

    @Test func fetchesPageThenLinkedIconAndCaches() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let store = store(directory, calls: calls) { url in
            if url.path == "/" { return FaviconResponse(data: Data("<link rel=\"icon\" href=\"/i.png\">".utf8), url: url, truncated: false) }
            if url.path == "/i.png" { return FaviconResponse(data: png(), url: url, truncated: false) }
            return nil
        }
        #expect(await store.image(for: "example.com") != nil)
        #expect(calls.all == ["https://example.com/", "https://example.com/i.png"])
        #expect(await store.image(for: "example.com") != nil)
        #expect(store.cachedImage(for: "example.com") != nil)
        #expect(calls.all.count == 2)
    }

    @Test func fallsBackToFaviconIco() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let store = store(directory, calls: calls) { url in url.path == "/favicon.ico" ? FaviconResponse(data: png(), url: url, truncated: false) : nil }
        #expect(await store.image(for: "example.com") != nil)
        #expect(calls.all.last == "https://example.com/favicon.ico")
    }

    @Test func oversizedIconIsRejectedAndNegativeCached() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let store = store(directory, calls: calls) { url in
            url.path == "/favicon.ico" ? FaviconResponse(data: png(), url: url, truncated: true) : nil
        }
        #expect(await store.image(for: "example.com") == nil)
        let count = calls.all.count
        #expect(await store.image(for: "example.com") == nil)
        #expect(calls.all.count == count)
    }

    @Test func negativeResultExpiresAfterADay() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let clock = Clock()
        let store = store(directory, calls: calls, now: { clock.date }) { _ in nil }
        #expect(await store.image(for: "example.com") == nil)
        let count = calls.all.count
        clock.date = clock.date.addingTimeInterval(SiteFaviconStore.negativeTTL + 60)
        #expect(await store.image(for: "example.com") == nil)
        #expect(calls.all.count > count)
    }

    @Test func invalidHostMakesNoRequest() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let store = store(directory, calls: calls) { _ in nil }
        #expect(await store.image(for: "localhost") == nil)
        #expect(calls.all.isEmpty)
    }
}

private final class Clock: @unchecked Sendable {
    var date = Date()
}
