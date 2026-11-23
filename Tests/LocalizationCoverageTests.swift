import Foundation
import Testing
@testable import SerialManager

/// Every user-facing literal in the app has an Italian translation (SPEC 0018, R27).
///
/// `xcodebuild` does not extract into `Localizable.xcstrings`, only the IDE does, so a string
/// added in code can stay untranslated with nothing to notice it. This suite reads the source and
/// the catalog and compares them, which is why it catches the next string somebody writes.
struct LocalizationCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The keys of the catalog that have an Italian value, plural variations included.
    private static func italianKeys() throws -> Set<String> {
        let url = root.appending(path: "Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = try #require(
            (json as? [String: Any])?["strings"] as? [String: Any], "no strings in the catalog")
        var keys: Set<String> = []
        for (key, value) in strings {
            let italian = ((value as? [String: Any])?["localizations"] as? [String: Any])?["it"]
            guard let italian = italian as? [String: Any] else { continue }
            // Either one unit, or one per plural category.
            if italian["stringUnit"] != nil || italian["variations"] != nil { keys.insert(key) }
        }
        return keys
    }

    /// The tokens that take a localizable literal as their first argument.
    private static let openers = [
        "String(localized: ", "Text(", "Label(", "Button(", "Section(", "TextField(", "Toggle(",
        "LabeledContent(", "DatePicker(", "Picker(", "ContentUnavailableView(", "Menu(",
        ".alert(", ".confirmationDialog(", ".help(", ".navigationTitle(", ".accessibilityLabel(",
        ".accessibilityValue(", ".accessibilityHint(", "prompt: ", "titleKey: ", "SheetHeader(",
    ]

    /// Every localizable literal in the app, as the catalog would key it: each `\(…)` becomes a
    /// format placeholder. Scanned character by character, because an interpolation can hold a
    /// string literal of its own (`\(name ?? "this attachment")`) and no regular expression over
    /// quotes survives that.
    private static func keys(inFileAt url: URL) throws -> [String] {
        // Comment lines are dropped: a comment quoting a string is not a string the app shows.
        let source = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let characters = Array(source)
        var found: [String] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "\"" else { index += 1; continue }
            // A literal only counts when one of the openers sits right before it.
            let prefix = String(characters[max(0, index - 26)..<index])
            guard openers.contains(where: prefix.hasSuffix) else { index += 1; continue }
            guard let (key, end) = scanLiteral(characters, from: index) else { index += 1; continue }
            found.append(key)
            index = end
        }
        return found
    }

    /// Reads the literal that starts at `start`, returning its catalog key and the index after it.
    private static func scanLiteral(
        _ characters: [Character], from start: Int
    ) -> (key: String, end: Int)? {
        var key = ""
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\"" { return (key, index + 1) }
            guard character == "\\", index + 1 < characters.count else {
                key.append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "(":
                // An interpolation: skip to its matching parenthesis, ignoring the parentheses
                // and quotes of any literal nested inside it.
                var depth = 0
                var cursor = index + 1
                var inString = false
                while cursor < characters.count {
                    let scanned = characters[cursor]
                    if scanned == "\"", characters[cursor - 1] != "\\" { inString.toggle() }
                    if !inString, scanned == "(" { depth += 1 }
                    if !inString, scanned == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor += 1
                }
                guard cursor < characters.count else { return nil }
                // The type decides %@ or %lld, which the source does not say, so the key is
                // matched with a placeholder wildcard later.
                key += "\u{FFFC}"
                index = cursor + 1
            case "u":
                // "\u{201C}": the catalog holds the character itself.
                var cursor = index + 3
                var hex = ""
                while cursor < characters.count, characters[cursor] != "}" {
                    hex.append(characters[cursor])
                    cursor += 1
                }
                if let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar) {
                    key.append(Character(unicode))
                }
                index = cursor + 1
            case "n": key.append("\n"); index += 2
            case "t": key.append("\t"); index += 2
            default: key.append(next); index += 2
            }
        }
        return nil
    }

    /// True when `key`, whose interpolations are object-replacement characters, is one of the
    /// catalog's keys once each placeholder is read for what it is.
    private static func isTranslated(_ key: String, in catalog: Set<String>) -> Bool {
        guard key.contains("\u{FFFC}") else { return catalog.contains(key) }
        let pattern = key
            .split(separator: "\u{FFFC}", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "%(?:@|lld|[0-9]*\\.?[0-9]*f)")
        guard let expression = try? NSRegularExpression(pattern: "^\(pattern)$") else {
            return false
        }
        return catalog.contains { candidate in
            expression.firstMatch(
                in: candidate,
                range: NSRange(location: 0, length: (candidate as NSString).length)) != nil
        }
    }

    @Test("Every localizable literal in the app has an Italian translation")
    func everyLiteralIsTranslated() throws {
        let catalog = try Self.italianKeys()
        let directory = Self.root.appending(path: "Sources", directoryHint: .isDirectory)
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var scanned = 0
        var missing: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // The fakes are DEBUG-only sample data and previews: nothing a user reads.
            guard !url.path(percentEncoded: false).contains("/Fakes/") else { continue }
            for key in try Self.keys(inFileAt: url) {
                scanned += 1
                if !Self.isTranslated(key, in: catalog) {
                    missing.append("\(url.lastPathComponent): \(key)")
                }
            }
        }
        #expect(scanned > 50, "only \(scanned) literals found: the scanner no longer matches")
        #expect(
            missing.isEmpty,
            "\(missing.count) literal(s) with no Italian translation:\n\(missing.sorted().joined(separator: "\n"))")
    }
}
