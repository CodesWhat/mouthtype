import AppKit
import Foundation
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
