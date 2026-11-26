import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches a favicon straight from the license's own site, with no third-party service
/// (SPEC 0030, D4 and D5).
///
/// Order: the `<link rel>` icons of the homepage HTML (relative hrefs resolved against the final,
/// post-redirect URL), then `<origin>/favicon.ico`.
///
/// Own-site boundary: only the license's own host and its `www.`/bare variant are ever contacted.
/// A candidate on another host is skipped before any request, and a redirect to another host is
/// not followed. An image is accepted only after ImageIO decodes a bounded thumbnail from it; what
/// is cached and returned is that thumbnail re-encoded as PNG, never the network bytes.
/// Concurrent requests for one URL share one fetch. Successes are kept in memory and on disk, keyed
/// by a hash of the normalized URL; failures are remembered in memory for the session only.
actor WebFaviconProvider: FaviconProvider {
    static let maxHTMLBytes = 1_000_000
    static let maxIconBytes = 512_000
    static let requestTimeout: TimeInterval = 10
    /// How long a disk entry is trusted before the icon is fetched again.
    static let diskLifetime: TimeInterval = 7 * 24 * 3600
    private static let maxCandidates = 4
    /// Longest side, in pixels, of the stored thumbnail.
    static let thumbnailPixels = 64

    /// Session for the app: ephemeral (no cookies, no persistent cache), short timeouts.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// `Caches/<bundle id>/Favicons`, or nil when the system has no caches directory.
    static func defaultCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundle = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"
        return caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    private let session: URLSession
    private let cacheDirectory: URL?
    private var memory: [String: Data] = [:]
    private var failed: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(session: URLSession = WebFaviconProvider.makeSession(), cacheDirectory: URL? = WebFaviconProvider.defaultCacheDirectory()) {
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    /// Cache key of a website: SHA-256 of its normalized address.
    static func cacheKey(for website: URL) -> String {
        let normalized = WebsiteURL.normalize(website.absoluteString) ?? website.absoluteString
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func favicon(for website: URL) async -> Data? {
        let key = Self.cacheKey(for: website)
        if let data = memory[key] { return data }
        if failed.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }
        if let data = readDisk(key) {
            memory[key] = data
            return data
        }

        let task = Task { await self.fetch(website) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            memory[key] = data
            writeDisk(data, key: key)
        } else {
            failed.insert(key)
        }
        return data
    }

    // MARK: - Fetching

    private func fetch(_ website: URL) async -> Data? {
        let hosts = Self.ownHosts(of: website)
        guard !hosts.isEmpty else { return nil }
        var base = website
        if let page = await download(website, hosts: hosts, limit: Self.maxHTMLBytes, truncate: true) {
            base = page.finalURL
            let html = String(decoding: page.data, as: UTF8.self)
            let candidates = Self.iconLinks(in: html, base: page.finalURL).filter { Self.isOwnSite($0, hosts: hosts) }
            for candidate in candidates.prefix(Self.maxCandidates) {
                if let icon = await downloadIcon(candidate, hosts: hosts) { return icon }
            }
        }
        guard let origin = Self.origin(of: base), Self.isOwnSite(origin, hosts: hosts) else { return nil }
        return await downloadIcon(origin.appendingPathComponent("favicon.ico"), hosts: hosts)
    }

    /// The validated thumbnail (PNG) of the image at `url`, or nil when it cannot be fetched or decoded.
    private func downloadIcon(_ url: URL, hosts: Set<String>) async -> Data? {
        guard let result = await download(url, hosts: hosts, limit: Self.maxIconBytes, truncate: false) else {
            return nil
        }
        return Self.thumbnailPNG(from: result.data)
    }

    /// Downloads `url`. Redirects are followed only inside `hosts`. HTTP errors, timeouts and,
    /// unless `truncate`, bodies over `limit` give nil. With `truncate`, a larger body is cut at
    /// `limit`: the icon links sit in the head.
    private func download(_ url: URL, hosts: Set<String>, limit: Int, truncate: Bool) async -> (data: Data, finalURL: URL)? {
        guard Self.isOwnSite(url, hosts: hosts) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: OwnSiteRedirectGuard(hosts: hosts))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            if !truncate, response.expectedContentLength > Int64(limit) { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit {
                    if truncate { break }
                    return nil
                }
                data.append(byte)
            }
            return (data, response.url ?? url)
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    /// Icon URLs declared by the page, `icon` and `shortcut icon` before `apple-touch-icon`, each
    /// group in document order. Only http(s) addresses are returned.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
            let attributePattern = try? NSRegularExpression(
                pattern: "([a-zA-Z][a-zA-Z0-9_-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")
        else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        var primary: [URL] = []
        var touch: [URL] = []
        for match in tagPattern.matches(in: html, range: whole) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            var attributes: [String: String] = [:]
            let tagWhole = NSRange(tag.startIndex..., in: tag)
            for attribute in attributePattern.matches(in: tag, range: tagWhole) {
                guard let nameRange = Range(attribute.range(at: 1), in: tag) else { continue }
                let name = tag[nameRange].lowercased()
                for group in 2...4 {
                    if let valueRange = Range(attribute.range(at: group), in: tag) {
                        attributes[name] = String(tag[valueRange])
                        break
                    }
                }
            }
            guard let rel = attributes["rel"]?.lowercased(), let rawHref = attributes["href"] else { continue }
            let href = decodeHTMLEntities(rawHref)
            let tokens = rel.split(whereSeparator: \.isWhitespace).map(String.init)
            let isTouch = tokens.contains { $0.hasPrefix("apple-touch-icon") }
            let isIcon = tokens.contains("icon")
            guard isTouch || isIcon,
                let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            if isIcon { primary.append(url) } else { touch.append(url) }
        }
        return primary + touch
    }

    /// Decodes HTML character references in one pass: `&amp; &lt; &gt; &quot; &apos; &#NN; &#xHH;`
    /// plus the uppercase `&AMP; &LT; &GT; &QUOT;` (HTML defines no `&APOS;`).
    /// Output is never rescanned, so `&amp;lt;` becomes `&lt;`, not `<`. Unknown or malformed
    /// references are kept as written.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "AMP": "&", "LT": "<", "GT": ">", "QUOT": "\"",
        ]
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            guard char == "&" else {
                output.append(char)
                index = text.index(after: index)
                continue
            }
            let afterAmp = text.index(after: index)
            if let semicolon = text[afterAmp...].prefix(12).firstIndex(of: ";") {
                let body = String(text[afterAmp..<semicolon])
                var decoded: Character?
                if let value = named[body] {
                    decoded = value
                } else if body.hasPrefix("#") {
                    let digits = body.dropFirst()
                    var code: UInt32?
                    if let first = digits.first, first == "x" || first == "X" {
                        let hex = digits.dropFirst()
                        if !hex.isEmpty, hex.allSatisfy(\.isHexDigit) { code = UInt32(hex, radix: 16) }
                    } else if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) {
                        code = UInt32(digits, radix: 10)
                    }
                    if let code, let scalar = Unicode.Scalar(code) { decoded = Character(scalar) }
                }
                if let decoded {
                    output.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            output.append(char)
            index = afterAmp
        }
        return output
    }

    private static func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Own-site boundary

    /// Hosts that count as the site of `website`: its own host and the `www.`/bare variant. Nothing else.
    static func ownHosts(of website: URL) -> Set<String> {
        guard let host = website.host?.lowercased(), !host.isEmpty else { return [] }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard !bare.isEmpty else { return [] }
        return [bare, "www." + bare]
    }

    /// True for an http(s) URL whose host is in `hosts`.
    static func isOwnSite(_ url: URL, hosts: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return false }
        return hosts.contains(host)
    }

    /// Refuses every redirect that leaves the own site; the foreign host is never contacted.
    private final class OwnSiteRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let hosts: Set<String>
        init(hosts: Set<String>) { self.hosts = hosts }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url, WebFaviconProvider.isOwnSite(url, hosts: hosts) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: - Decoding

    /// Decodes a bounded thumbnail with ImageIO and returns it re-encoded as PNG, or nil when the
    /// data is empty, truncated or not an image. Pure function, runs on the caller's executor.
    static func thumbnailPNG(from data: Data, maxPixels: Int = thumbnailPixels) -> Data? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func decodesAsImage(_ data: Data) -> Bool {
        thumbnailPNG(from: data) != nil
    }

    // MARK: - Disk cache

    private func fileURL(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent(key, isDirectory: false)
    }

    /// Cached bytes when the file exists, is younger than `diskLifetime` and still decodes.
    private func readDisk(_ key: String) -> Data? {
        guard let url = fileURL(key),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < Self.diskLifetime,
            let data = try? Data(contentsOf: url),
            Self.decodesAsImage(data)
        else { return nil }
        return data
    }

    private func writeDisk(_ data: Data, key: String) {
        guard let directory = cacheDirectory, let url = fileURL(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
