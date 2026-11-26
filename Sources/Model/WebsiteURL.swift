import Foundation

/// Normalization of the optional "Web" field of a license (SPEC 0030, D2).
enum WebsiteURL {
    /// The stored form of `input`: `""` when blank, otherwise an `http` or `https` address.
    ///
    /// Trims the input, prepends `https://` when there is no scheme, and accepts only `http` and
    /// `https` with a non-empty host and no whitespace. Returns nil when the input is not acceptable.
    static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let candidate = hasSchemePrefix(trimmed) && !isHostAndPort(trimmed) ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return candidate
    }

    /// A scheme counts only at the very start of the string: `^[A-Za-z][A-Za-z0-9+.-]*:`.
    private static func hasSchemePrefix(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
    }

    /// A dotted host and an all-digit port, optionally followed by a path, query or fragment, such
    /// as `example.test:8080/app`: the colon separates a port, it is not a scheme. The host needs a
    /// dot, so `mailto:123` stays a scheme and is refused.
    private static func isHostAndPort(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+:[0-9]+([/?#].*)?$", options: .regularExpression) != nil
    }

    /// The URL to fetch a favicon for, or nil when `website` is blank or not a valid address.
    static func url(for website: String) -> URL? {
        guard let normalized = normalize(website), !normalized.isEmpty else { return nil }
        return URL(string: normalized)
    }
}
