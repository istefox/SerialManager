import Foundation
import ImageIO
import Testing
@testable import SerialManager

/// `WebFaviconProvider` against a stubbed network (SPEC 0030, D4 and D5, test A6).
/// No test reaches the real network: every request goes through `StubURLProtocol`.
struct FaviconProviderTests {
    private func html(_ head: String) -> Data {
        Data("<!doctype html><html><head><title>Example</title>\(head)</head><body></body></html>".utf8)
    }

    private func provider(cacheDirectory: URL? = nil) -> WebFaviconProvider {
        WebFaviconProvider(session: StubURLProtocol.makeSession(), cacheDirectory: cacheDirectory)
    }

    private func page(_ host: String, path: String = "/") -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    /// Pixel width of the returned thumbnail. The provider re-encodes, so bytes never equal the
    /// served file; the test icons differ by width instead.
    private func width(_ data: Data?) -> Int? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    // MARK: Parsing

    @Test func parsesRelativeAndQuotedLinks() {
        let base = URL(string: "https://example.test/app/")!
        let links = WebFaviconProvider.iconLinks(
            in: """
            <link rel="stylesheet" href="/style.css">
            <link rel="apple-touch-icon" href="/touch.png">
            <LINK HREF='img/small.png' REL='shortcut icon'>
            <link rel=icon href=/plain.ico>
            <link rel="icon" href="ftp://example.test/no.ico">
            """,
            base: base)
        #expect(links.map(\.absoluteString) == [
            "https://example.test/app/img/small.png",
            "https://example.test/plain.ico",
            "https://example.test/touch.png",
        ])
    }

    @Test func decodesCharacterReferencesOnce() {
        let decode = WebFaviconProvider.decodeHTMLEntities
        #expect(decode("a&amp;b&lt;&gt;&quot;&apos;&#39;") == "a&b<>\"''")
        #expect(decode("&#65;&#x42;&#X43;") == "ABC")
        #expect(decode("&amp;lt;") == "&lt;")
        #expect(decode("&AMP;&LT;&GT;&QUOT;") == "&<>\"")
        #expect(decode("&Amp; &APOS;") == "&Amp; &APOS;")
        #expect(decode("&AMP;lt;") == "&lt;")
        #expect(decode("&bogus; &#; &#xZZ; & &#99999999999;") == "&bogus; &#; &#xZZ; & &#99999999999;")
    }

    @Test func decodesEntitiesInHrefBeforeResolving() {
        let links = WebFaviconProvider.iconLinks(
            in: #"<link rel="icon" href="/icon?size=32&amp;theme=dark">"#,
            base: URL(string: "https://example.test/")!)
        #expect(links.map(\.absoluteString) == ["https://example.test/icon?size=32&theme=dark"])
    }

    // MARK: Link in the HTML

    @Test func requestsTheDecodedIconUrl() async {
        let host = Stub.host()
        StubURLProtocol.set(
            "https://\(host)/", .ok(html(#"<link rel="icon" href="/icon?size=32&amp;theme=dark">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/icon?size=32&theme=dark", .ok(Stub.png(width: 21)))

        let result = await provider().favicon(for: page(host))

        #expect(width(result) == 21)
        #expect(StubURLProtocol.requests(forHost: host).contains("https://\(host)/icon?size=32&theme=dark"))
    }

    @Test func requestsTheDecodedIconUrlForUppercaseAmpEntity() async {
        let host = Stub.host()
        StubURLProtocol.set(
            "https://\(host)/", .ok(html(#"<link rel="icon" href="/icon?size=32&AMP;theme=dark">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/icon?size=32&theme=dark", .ok(Stub.png(width: 22)))

        let result = await provider().favicon(for: page(host))

        #expect(width(result) == 22)
        #expect(StubURLProtocol.requests(forHost: host).contains("https://\(host)/icon?size=32&theme=dark"))
    }

    @Test func resolvesARelativeIconLink() async {
        let host = Stub.host()
        let icon = Stub.png(width: 3)
        StubURLProtocol.set("https://\(host)/", .ok(html(#"<link rel="icon" href="/assets/i.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/assets/i.png", .ok(icon))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 9)))

        let result = await provider().favicon(for: page(host))

        #expect(width(result) == 3)
        #expect(!StubURLProtocol.requests(forHost: host).contains("https://\(host)/favicon.ico"))
    }

    // MARK: Own-site boundary (D4)

    @Test func resolvesAgainstTheUrlAfterAnOwnSiteRedirect() async {
        let host = Stub.host()
        StubURLProtocol.set("http://\(host)/", .redirect(to: "https://www.\(host)/home/"))
        StubURLProtocol.set(
            "https://www.\(host)/home/", .ok(html(#"<link rel="icon" href="icon.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://www.\(host)/home/icon.png", .ok(Stub.png(width: 4)))

        #expect(width(await provider().favicon(for: URL(string: "http://\(host)/")!)) == 4)
    }

    @Test func aCrossHostRedirectIsNotFollowedAndTheForeignHostIsNeverRequested() async {
        let host = Stub.host()
        let foreign = Stub.host()
        StubURLProtocol.set("https://\(host)/", .redirect(to: "https://\(foreign)/home/"))
        StubURLProtocol.set("https://\(foreign)/home/", .ok(html(#"<link rel="icon" href="/i.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(foreign)/i.png", .ok(Stub.png(width: 4)))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 14)))

        // The page redirect is refused; the fallback on the own origin still works.
        #expect(width(await provider().favicon(for: page(host))) == 14)
        #expect(StubURLProtocol.requests(forHost: foreign).isEmpty)
    }

    @Test func aCrossHostRedirectOnAnIconIsNotFollowed() async {
        let host = Stub.host()
        let foreign = Stub.host()
        StubURLProtocol.set("https://\(host)/", .ok(html(#"<link rel="icon" href="/i.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/i.png", .redirect(to: "https://\(foreign)/i.png"))
        StubURLProtocol.set("https://\(foreign)/i.png", .ok(Stub.png(width: 4)))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 15)))

        #expect(width(await provider().favicon(for: page(host))) == 15)
        #expect(StubURLProtocol.requests(forHost: foreign).isEmpty)
    }

    @Test func anIconLinkOnAForeignHostIsSkipped() async {
        let host = Stub.host()
        let foreign = Stub.host()
        StubURLProtocol.set(
            "https://\(host)/",
            .ok(html(#"<link rel="icon" href="https://\#(foreign)/i.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(foreign)/i.png", .ok(Stub.png(width: 4)))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 16)))

        #expect(width(await provider().favicon(for: page(host))) == 16)
        #expect(StubURLProtocol.requests(forHost: foreign).isEmpty)
    }

    @Test func ownSiteMeansTheSameHostOrItsWwwVariant() {
        let hosts = WebFaviconProvider.ownHosts(of: URL(string: "https://Example.test/x")!)
        #expect(WebFaviconProvider.ownHosts(of: URL(string: "https://www.example.test/")!) == hosts)
        #expect(WebFaviconProvider.isOwnSite(URL(string: "https://example.test/i.png")!, hosts: hosts))
        #expect(WebFaviconProvider.isOwnSite(URL(string: "http://WWW.example.test/i.png")!, hosts: hosts))
        #expect(!WebFaviconProvider.isOwnSite(URL(string: "https://cdn.example.test/i.png")!, hosts: hosts))
        #expect(!WebFaviconProvider.isOwnSite(URL(string: "https://example.test.evil.test/i.png")!, hosts: hosts))
        #expect(!WebFaviconProvider.isOwnSite(URL(string: "ftp://example.test/i.png")!, hosts: hosts))
    }

    // MARK: Decoding

    @Test func malformedImageIsSkippedAndTheCacheHoldsOnlyValidData() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = directory.url.appending(path: "Favicons", directoryHint: .isDirectory)
        let host = Stub.host()
        let truncated = Stub.png(width: 20).prefix(40)
        #expect(WebFaviconProvider.thumbnailPNG(from: Data(truncated)) == nil)
        StubURLProtocol.set("https://\(host)/", .ok(html(#"<link rel="icon" href="/bad.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/bad.png", .ok(Data(truncated)))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 17)))

        let result = await provider(cacheDirectory: cache).favicon(for: page(host))

        #expect(width(result) == 17)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))
        #expect(files.count == 1)
        let cached = try Data(contentsOf: cache.appending(path: files[0]))
        #expect(cached == result)
        #expect(WebFaviconProvider.thumbnailPNG(from: cached) != nil)
    }

    @Test func aLargeImageIsReducedToABoundedThumbnail() async throws {
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(Stub.png(width: 300)))

        let result = await provider().favicon(for: page(host))

        let side = try #require(width(result))
        #expect(side <= WebFaviconProvider.thumbnailPixels)
    }

    @Test func triesTheNextLinkWhenTheFirstIsNotAnImage() async {
        let host = Stub.host()
        let icon = Stub.png(width: 5)
        StubURLProtocol.set("https://\(host)/", .ok(
            html(#"<link rel="icon" href="/bad.svg"><link rel="apple-touch-icon" href="/touch.png">"#),
            contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/bad.svg", .ok(Data("<svg/>".utf8)))
        StubURLProtocol.set("https://\(host)/touch.png", .ok(icon))

        #expect(width(await provider().favicon(for: page(host))) == 5)
    }

    // MARK: Fallback

    @Test func fallsBackToFaviconIcoWhenThePageDeclaresNone() async {
        let host = Stub.host()
        let icon = Stub.png(width: 6)
        StubURLProtocol.set("https://\(host)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(icon))

        #expect(width(await provider().favicon(for: page(host, path: "/"))) == 6)
    }

    @Test func fallsBackToTheOriginWhenThePageFails() async {
        let host = Stub.host()
        let icon = Stub.png(width: 7)
        StubURLProtocol.set("https://\(host)/shop/", .status(500))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(icon))

        #expect(width(await provider().favicon(for: page(host, path: "/shop/"))) == 7)
    }

    // MARK: Failures give nil

    @Test func httpErrorGivesNil() async {
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .status(500))
        StubURLProtocol.set("https://\(host)/favicon.ico", .status(404))

        #expect(await provider().favicon(for: page(host)) == nil)
    }

    @Test func timeoutGivesNil() async {
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .failure(.timedOut))
        StubURLProtocol.set("https://\(host)/favicon.ico", .failure(.timedOut))

        #expect(await provider().favicon(for: page(host)) == nil)
    }

    @Test func dataThatIsNotAnImageGivesNil() async {
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .ok(html(#"<link rel="icon" href="/i.png">"#), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/i.png", .ok(Data("definitely not an image".utf8)))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(html("")))

        #expect(await provider().favicon(for: page(host)) == nil)
    }

    @Test func anIconOverTheSizeLimitIsRefused() async {
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set(
            "https://\(host)/favicon.ico",
            .ok(Stub.png() + Data(count: WebFaviconProvider.maxIconBytes + 1)))

        #expect(await provider().favicon(for: page(host)) == nil)
    }

    @Test func aFailureIsRememberedForTheSession() async {
        let host = Stub.host()
        let sut = provider()
        StubURLProtocol.set("https://\(host)/", .status(500))
        StubURLProtocol.set("https://\(host)/favicon.ico", .status(404))

        #expect(await sut.favicon(for: page(host)) == nil)
        let after = StubURLProtocol.requests(forHost: host).count
        #expect(await sut.favicon(for: page(host)) == nil)
        #expect(StubURLProtocol.requests(forHost: host).count == after)
    }

    // MARK: Deduplication and cache

    @Test func concurrentRequestsForOneUrlShareOneFetch() async {
        let host = Stub.host()
        let icon = Stub.png(width: 8)
        StubURLProtocol.set("https://\(host)/", .ok(html(""), contentType: "text/html", delay: 0.3))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(icon))
        let sut = provider()
        let url = page(host)

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<6 { group.addTask { await sut.favicon(for: url) } }
            var all: [Data?] = []
            for await result in group { all.append(result) }
            return all
        }

        #expect(results.count == 6)
        #expect(results.allSatisfy { width($0) == 8 })
        #expect(StubURLProtocol.requests(forHost: host).filter { $0 == "https://\(host)/" }.count == 1)
        #expect(StubURLProtocol.requests(forHost: host).filter { $0.hasSuffix("/favicon.ico") }.count == 1)
    }

    @Test func aChangedAddressUsesADifferentCacheEntry() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = directory.url.appending(path: "Favicons", directoryHint: .isDirectory)
        let hostA = Stub.host()
        let hostB = Stub.host()
        let iconA = Stub.png(width: 10)
        let iconB = Stub.png(width: 11)
        StubURLProtocol.set("https://\(hostA)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set("https://\(hostA)/favicon.ico", .ok(iconA))
        StubURLProtocol.set("https://\(hostB)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set("https://\(hostB)/favicon.ico", .ok(iconB))

        #expect(WebFaviconProvider.cacheKey(for: page(hostA)) != WebFaviconProvider.cacheKey(for: page(hostB)))

        let first = provider(cacheDirectory: cache)
        #expect(width(await first.favicon(for: page(hostA))) == 10)
        #expect(width(await first.favicon(for: page(hostB))) == 11)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))
        #expect(files.count == 2)
    }

    @Test func theDiskCacheAnswersWithoutTheNetwork() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = directory.url.appending(path: "Favicons", directoryHint: .isDirectory)
        let host = Stub.host()
        let icon = Stub.png(width: 12)
        StubURLProtocol.set("https://\(host)/", .ok(html(""), contentType: "text/html"))
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(icon))

        #expect(width(await provider(cacheDirectory: cache).favicon(for: page(host))) == 12)
        let requested = StubURLProtocol.requests(forHost: host).count

        // A new provider has an empty memory cache: only the disk can answer.
        #expect(width(await provider(cacheDirectory: cache).favicon(for: page(host))) == 12)
        #expect(StubURLProtocol.requests(forHost: host).count == requested)
    }

    @Test func aFailureIsNeverWrittenToDisk() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = directory.url.appending(path: "Favicons", directoryHint: .isDirectory)
        let host = Stub.host()
        StubURLProtocol.set("https://\(host)/", .status(500))
        StubURLProtocol.set("https://\(host)/favicon.ico", .status(404))

        #expect(await provider(cacheDirectory: cache).favicon(for: page(host)) == nil)

        // A new provider, as after a relaunch, tries the network again and may now succeed.
        let icon = Stub.png(width: 13)
        StubURLProtocol.set("https://\(host)/favicon.ico", .ok(icon))
        #expect(width(await provider(cacheDirectory: cache).favicon(for: page(host))) == 13)
    }
}
