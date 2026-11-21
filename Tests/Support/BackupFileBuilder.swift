import CryptoKit
import Foundation
@testable import SerialManager

/// Test-only writer of backup files with any header values (plan 0010, T2).
///
/// Writes the header by the literal offsets of docs/adr/0002-backup-format.md, section 3, never
/// through `BackupFormat.header`, so the reader is checked against the ADR and not against the writer.
struct BackupFileBuilder {
    var magic = Data("SMBACKUP".utf8)
    var version: UInt16 = 1
    var kdfID: UInt8 = 0x01
    var iterations: UInt32 = 600_000
    var salt = BackupFixtures.salt
    var cipherID: UInt8 = 0x01
    var nonce = BackupFixtures.nonceBytes

    /// Bytes `[0, 33+S)`: magic, version, KDF id, iterations, salt length, salt, cipher id, nonce,
    /// ciphertext length. Integers big-endian.
    func header(ciphertextLength: Int) -> Data {
        var data = magic
        data.append(contentsOf: [UInt8(version >> 8), UInt8(version & 0xFF), kdfID])
        data.append(contentsOf: Self.bigEndian(iterations))
        data.append(UInt8(salt.count))
        data.append(salt)
        data.append(cipherID)
        data.append(nonce)
        data.append(contentsOf: Self.bigEndian(UInt32(ciphertextLength)))
        return data
    }

    /// Header, `ciphertextLength` zero bytes and a zero tag: the sizes agree, the box never opens.
    /// For checks that must stop before any key is derived.
    func unsealed(ciphertextLength: Int = 32) -> Data {
        var data = header(ciphertextLength: ciphertextLength)
        data.append(Data(count: ciphertextLength + 16))
        return data
    }

    /// `plaintext` sealed with the production key derivation and AES-GCM, the header as associated data.
    func sealed(_ plaintext: Data, password: String) throws -> Data {
        let header = header(ciphertextLength: plaintext.count)
        let key = try BackupKeyDerivation.key(password: password, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(
            plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        var data = header
        data.append(box.ciphertext)
        data.append(box.tag)
        return data
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// JSON payloads built field by field, for the decoder and validation tests. Fake data only.
enum BackupPayloadJSON {
    static let editorID = "00000000-0000-4000-8000-000000000001"
    static let viewerID = "00000000-0000-4000-8000-000000000002"

    /// One entry with every key of ADR 0002 section 6.
    static func entry(id: String = editorID, name: String = "Sample Editor") -> [String: Any] {
        [
            "id": id,
            "productName": name,
            "vendor": "Example Software",
            "registeredEmail": "user@example.com",
            "purchaseDate": NSNull(),
            "version": "1.0",
            "notes": "",
            "createdAt": "2026-01-01T09:00:00.250Z",
            "updatedAt": "2026-01-01T09:00:00.500Z",
            "serial": "FAKE-0000-0000-0000",
        ]
    }

    static func payload(_ licenses: Any, exportedAt: String = "2026-01-01T10:00:00.750Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["exportedAt": exportedAt, "licenses": licenses])
    }

    static func payload(entries: [[String: Any]]) throws -> Data {
        try payload(entries as Any)
    }
}
