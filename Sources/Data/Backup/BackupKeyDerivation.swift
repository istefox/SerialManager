import CommonCrypto
import CryptoKit
import Foundation

/// Password-based key derivation of backup format version 1 (docs/adr/0002-backup-format.md,
/// sections 1 and 8). Shared by export and import.
enum BackupKeyDerivation {
    /// Length of the derived AES-256 key in bytes.
    static let keyLength = 32

    /// The bytes fed to PBKDF2: the password normalized to Unicode NFC, then encoded as UTF-8,
    /// so the same password typed with another keyboard or input method gives the same key.
    static func passwordBytes(_ password: String) -> [UInt8] {
        Array(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// PBKDF2-HMAC-SHA256 over `passwordBytes(password)`, 32-byte output.
    ///
    /// Synchronous and CPU bound: call it off the main actor. A non-success status from
    /// CommonCrypto throws `BackupExportError.encryptionFailed`.
    static func key(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordBytes = passwordBytes(password)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let derivedCount = derived.count
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBytes { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordBuffer.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derivedCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BackupExportError.encryptionFailed }
        return SymmetricKey(data: derived)
    }
}
