import CryptoKit
import Foundation
@testable import SerialManager

/// Test-only reader of a version 1 backup (plan 0009, section 2.1).
///
/// Parses the file by the literal offsets of docs/adr/0002-backup-format.md, section 3, never
/// through `BackupFormat.header`, so a wrong layout in the writer cannot pass a round trip. It
/// does not implement the ordered checks and error mapping of the production import (#10).
struct BackupFileReader {
    struct Malformed: Error, Equatable {
        let reason: String
    }

    struct Contents {
        let magic: Data
        let version: UInt16
        let kdfID: UInt8
        let iterations: UInt32
        let saltLength: UInt8
        let salt: Data
        let cipherID: UInt8
        let nonce: Data
        let ciphertextLength: UInt32
        /// Bytes `[0, 33+S)`, the associated data of the sealed box.
        let header: Data
        let ciphertext: Data
        let tag: Data
    }

    /// Parses the clear header and splits the file; derives no key.
    static func parse(_ file: Data) throws -> Contents {
        let bytes = [UInt8](file)
        guard bytes.count >= 16 else { throw Malformed(reason: "short header") }
        let saltLength = Int(bytes[15])
        let headerLength = 33 + saltLength
        guard bytes.count >= headerLength else { throw Malformed(reason: "cut header") }
        let ciphertextLength = bigEndian(bytes[(29 + saltLength)..<(33 + saltLength)])
        guard bytes.count == headerLength + Int(ciphertextLength) + 16 else {
            throw Malformed(reason: "size mismatch")
        }
        let ciphertextEnd = headerLength + Int(ciphertextLength)
        return Contents(
            magic: Data(bytes[0..<8]),
            version: UInt16(bigEndian(bytes[8..<10])),
            kdfID: bytes[10],
            iterations: bigEndian(bytes[11..<15]),
            saltLength: bytes[15],
            salt: Data(bytes[16..<(16 + saltLength)]),
            cipherID: bytes[16 + saltLength],
            nonce: Data(bytes[(17 + saltLength)..<(29 + saltLength)]),
            ciphertextLength: ciphertextLength,
            header: Data(bytes[0..<headerLength]),
            ciphertext: Data(bytes[headerLength..<ciphertextEnd]),
            tag: Data(bytes[ciphertextEnd...])
        )
    }

    /// Decrypts the payload with the production key derivation and the header as associated data.
    static func decrypt(_ file: Data, password: String) throws -> (contents: Contents, plaintext: Data) {
        let contents = try parse(file)
        let key = try BackupKeyDerivation.key(
            password: password, salt: contents.salt, iterations: contents.iterations)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: contents.nonce),
            ciphertext: contents.ciphertext,
            tag: contents.tag)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: contents.header)
        return (contents, plaintext)
    }

    /// Decrypts and decodes the payload.
    static func payload(_ file: Data, password: String) throws -> BackupPayload {
        let plaintext = try decrypt(file, password: password).plaintext
        return try BackupPayload.makeDecoder().decode(BackupPayload.self, from: plaintext)
    }

    private static func bigEndian(_ slice: ArraySlice<UInt8>) -> UInt32 {
        slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
