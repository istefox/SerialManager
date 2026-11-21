import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import SerialManager

/// PBKDF2-HMAC-SHA256 and the NFC rule (ADR 0002, sections 1 and 8; plan 0009, B1).
/// The NFC rule is pinned by literal bytes and a direct CommonCrypto call, not only by a round
/// trip through the shared function.
struct BackupKeyDerivationTests {
    /// `cafe` + U+0301 COMBINING ACUTE ACCENT, in NFC: precomposed `é` = C3 A9.
    private let nfcBytes: [UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9, 0x2D, 0x73, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x2D, 0x70, 0x77]

    @Test func passwordBytesAreNFCThenUTF8() {
        #expect(BackupKeyDerivation.passwordBytes("cafe\u{301}-sample-pw") == nfcBytes)
        #expect(BackupKeyDerivation.passwordBytes("caf\u{E9}-sample-pw") == nfcBytes)
    }

    @Test func passwordBytesKeepCompatibilityCharacters() {
        // NFC, not NFKC: the ligature U+FB01 stays as it is (EF AC 81).
        #expect(BackupKeyDerivation.passwordBytes("\u{FB01}") == [0xEF, 0xAC, 0x81])
    }

    @Test func keyEqualsDirectCommonCryptoOverLiteralBytes() throws {
        let salt = Data((0..<16).map { UInt8(0x30 + $0) })
        let key = try BackupKeyDerivation.key(password: "cafe\u{301}-sample-pw", salt: salt, iterations: 600_000)

        var expected = [UInt8](repeating: 0, count: 32)
        let status = nfcBytes.withUnsafeBufferPointer { password in
            [UInt8](salt).withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(password.baseAddress!).assumingMemoryBound(to: CChar.self),
                    password.count,
                    saltBuffer.baseAddress,
                    saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    600_000,
                    &expected,
                    32
                )
            }
        }
        try #require(status == kCCSuccess)
        #expect(key.withUnsafeBytes { [UInt8]($0) } == expected)
    }

    /// RFC 7914 section 11: PBKDF2-HMAC-SHA-256 (P="passwd", S="salt", c=1, dkLen=64),
    /// first 32 bytes (copied from https://www.rfc-editor.org/rfc/rfc7914.txt on 2026-11-21).
    @Test func matchesRFC7914Vector() throws {
        let expected: [UInt8] = [
            0x55, 0xAC, 0x04, 0x6E, 0x56, 0xE3, 0x08, 0x9F, 0xEC, 0x16, 0x91, 0xC2, 0x25, 0x44, 0xB6, 0x05,
            0xF9, 0x41, 0x85, 0x21, 0x6D, 0xDE, 0x04, 0x65, 0xE6, 0x8B, 0x9D, 0x57, 0xC2, 0x0D, 0xAC, 0xBC,
        ]
        let key = try BackupKeyDerivation.key(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        #expect(key.bitCount == 256)
        #expect(key.withUnsafeBytes { [UInt8]($0) } == expected)
    }
}
