import AppKit
import Foundation
import os

/// URL protocol that answers from a table, so no test reaches the network.
///
/// Routes are keyed by the full URL string. Every test uses a host of its own (`Stub.host()`), so
/// tests that run in parallel never see each other's routes or requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Route: Sendable {
        case ok(Data, contentType: String = "application/octet-stream", delay: TimeInterval = 0)
        case status(Int)
        case failure(URLError.Code)
        case redirect(to: String)
    }

    private static let routes = OSAllocatedUnfairLock<[String: Route]>(initialState: [:])
    private static let log = OSAllocatedUnfairLock<[String]>(initialState: [])

    static func set(_ url: String, _ route: Route) {
        routes.withLock { $0[url] = route }
    }

    /// Every URL requested so far, in order, across all tests.
    static func requests(forHost host: String) -> [String] {
        log.withLock { $0.filter { URL(string: $0)?.host == host } }
    }

    /// A session that sends everything through this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.log.withLock { $0.append(url.absoluteString) }
        let route = Self.routes.withLock { $0[url.absoluteString] } ?? .status(404)
        switch route {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code):
            respond(url: url, status: code, contentType: "text/plain", body: Data())
        case .ok(let body, let contentType, let delay):
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            respond(url: url, status: 200, contentType: contentType, body: body)
        case .redirect(let target):
            guard let targetURL = URL(string: target),
                let response = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])
            else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
            // The loading system starts a new load for the target; this one is done.
        }
    }

    private func respond(url: URL, status: Int, contentType: String, body: Data) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "Content-Length": String(body.count)])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

enum Stub {
    /// A host no other test uses. `.test` never resolves, so a leak to the real network fails loudly.
    static func host() -> String {
        "h" + UUID().uuidString.prefix(8).lowercased() + ".example.test"
    }

    /// A small valid PNG of the given width, so two icons differ byte for byte.
    static func png(width: Int = 1) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let data = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return data
    }
}
