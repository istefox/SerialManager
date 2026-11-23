import Foundation
import Testing
@testable import SerialManager

/// The isolation audit of SPEC 0018, A18, plus R28 on the fixtures.
///
/// Debug and Release share one bundle identifier, so they share the Application Support folder and
/// the Keychain service: a test that reached either would read or destroy the owner's own library.
/// This suite reads the source of the app and of the test target and asserts that no test can.
/// It is a grep, deliberately: it catches the next test somebody writes, not just today's.
struct AttachmentIsolationAuditTests {

    /// The repository root, found from this file's own path.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repository root

    /// Every `.swift` file under a directory, with its path relative to the root.
    private static func sources(in folder: String) throws -> [(name: String, text: String)] {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "\(folder) is not readable from \(root.path(percentEncoded: false))")
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // This file names every forbidden pattern on purpose, so it audits everything but
            // itself. Comment lines are stripped: a comment that explains why a test avoids the
            // real Keychain is not a test that reaches it.
            guard url.lastPathComponent != "AttachmentIsolationAuditTests.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            found.append((url.lastPathComponent, code))
        }
        #expect(!found.isEmpty, "\(folder) holds no Swift file")
        return found
    }

    /// The file that is allowed to name the real Keychain and the real folder: the one that wires
    /// them, which no test instantiates.
    private static let wiringFiles: Set<String> = [
        "LicenseLibrary.swift", "SerialManagerApp.swift", "KeychainAttachmentKeyStore.swift",
        "KeychainSerialStore.swift", "AttachmentOpener.swift",
    ]

    @Test("No test builds the real Keychain stores or the real library")
    func testsNeverTouchTheRealKeychainOrFolder() throws {
        // `KeychainSerialStore(service:client:)` with an injected fake client is fine, which is
        // why the patterns are the no-argument and defaulted forms that reach the real system.
        let forbidden = [
            "KeychainAttachmentKeyStore()",
            "KeychainSerialStore()",
            "LicenseLibrary.makeRepository()",
            "LicenseLibrary.defaultStoreURL",
            "defaultAttachmentsDirectory",
            "AttachmentOpener.defaultDirectory",
            ".applicationSupportDirectory",
        ]
        for file in try Self.sources(in: "Tests") {
            for pattern in forbidden {
                #expect(
                    !file.text.contains(pattern),
                    "\(file.name) names \(pattern): a test must inject its own directory and key store (A18)")
            }
        }
    }

    @Test("Only the wiring files name the real Keychain or the real Application Support folder")
    func productionWiringIsInOnePlace() throws {
        for file in try Self.sources(in: "Sources") where !Self.wiringFiles.contains(file.name) {
            for pattern in ["KeychainAttachmentKeyStore(", ".applicationSupportDirectory"] {
                #expect(
                    !file.text.contains(pattern),
                    "\(file.name) reaches the real system directly; keep that in LicenseLibrary (R9, R10)")
            }
        }
    }

    @Test("Every serial-shaped literal in the app and the tests is obviously fake")
    func noPlausibleRealSerialIsCommitted() throws {
        // The repository is public (CLAUDE.md). A serial-shaped literal is any quoted run of
        // upper-case groups joined by hyphens; every one of them must open with a word that says
        // out loud that it is not real.
        let shape = try NSRegularExpression(
            pattern: "\"([A-Z][A-Z0-9]{2,}(?:-[A-Z0-9]{3,})+)\"")
        let fakePrefixes = [
            "FAKE", "SAMPLE", "TEST", "EXAMPLE", "ACME", "BETA", "ZETA", "FICTIONAL",
            "PLACEHOLDER", "SMOKE", "DEMO", "NAME", "LICENCE",
        ]
        for folder in ["Sources", "Tests"] {
            for file in try Self.sources(in: folder) {
                let text = file.text as NSString
                for match in shape.matches(
                    in: file.text, range: NSRange(location: 0, length: text.length))
                {
                    let literal = text.substring(with: match.range(at: 1))
                    let first = literal.split(separator: "-").first.map(String.init) ?? literal
                    #expect(
                        fakePrefixes.contains(first),
                        "\(file.name) holds “\(literal)”, which does not read as an obviously fake value (R28)")
                }
            }
        }
    }

    @Test("No test file carries attachment bytes that look like a real license file")
    func attachmentFixturesAreObviouslyFake() throws {
        // The fixtures build their bytes from a short ASCII marker or a repeated byte; nothing in
        // the tests embeds base64 of real content. A long base64 literal would be the smell.
        let base64 = try NSRegularExpression(pattern: "\"[A-Za-z0-9+/]{120,}={0,2}\"")
        for file in try Self.sources(in: "Tests") {
            let text = file.text as NSString
            #expect(
                base64.firstMatch(in: file.text, range: NSRange(location: 0, length: text.length))
                    == nil,
                "\(file.name) embeds a long base64 literal: build fixture bytes in code instead (R28)")
        }
    }
}
