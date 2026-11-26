import AppKit
import SwiftUI

/// Leading icon of a sidebar row: the site's favicon once loaded, the `key.horizontal` symbol while
/// loading and on any failure (SPEC 0030, D6). Decorative, so hidden from accessibility.
///
/// The provider hands back a validated PNG thumbnail (SPEC 0030, D4); this view never sees raw
/// network bytes. The loaded image is stored together with the address that produced it and is
/// drawn only while that address is still the current one, so an edit or a cleared field shows the
/// symbol at once, before the new load finishes.
struct FaviconIcon: View {
    let website: String
    @Environment(\.faviconProvider) private var provider
    @State private var loaded: (website: String, image: NSImage)?

    static let size: CGFloat = 18

    var body: some View {
        Group {
            if let loaded, loaded.website == website {
                Image(nsImage: loaded.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: website) {
            guard let url = WebsiteURL.url(for: website) else {
                loaded = nil
                return
            }
            let data = await provider.favicon(for: url)
            guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return }
            loaded = (website, image)
        }
    }
}
