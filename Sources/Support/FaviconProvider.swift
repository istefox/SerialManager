import SwiftUI

/// Source of the favicon shown as a sidebar row icon (SPEC 0030, D5).
///
/// Returns the bytes of an image that decodes, or nil on any failure. Bytes rather than an image
/// type, so the value is `Sendable` and the view decodes it on the main actor.
protocol FaviconProvider: Sendable {
    func favicon(for website: URL) async -> Data?
}

/// Provider that never has an icon. The environment default, so a view built without the real
/// provider (a preview, a test) never touches the network.
struct NoFaviconProvider: FaviconProvider {
    func favicon(for website: URL) async -> Data? { nil }
}

/// In-memory fake: answers from a dictionary and counts the requests.
actor InMemoryFaviconProvider: FaviconProvider {
    private var icons: [URL: Data]
    private(set) var requests: [URL] = []

    init(icons: [URL: Data] = [:]) {
        self.icons = icons
    }

    func favicon(for website: URL) async -> Data? {
        requests.append(website)
        return icons[website]
    }
}

private struct FaviconProviderKey: EnvironmentKey {
    static let defaultValue: any FaviconProvider = NoFaviconProvider()
}

extension EnvironmentValues {
    var faviconProvider: any FaviconProvider {
        get { self[FaviconProviderKey.self] }
        set { self[FaviconProviderKey.self] = newValue }
    }
}
