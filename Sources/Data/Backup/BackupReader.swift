import CryptoKit
import Foundation

/// Reads and decrypts a backup file (docs/adr/0002-backup-format.md, section 5; plan 0010, 2.6).
///
/// The password, the derived key and the plaintext are locals: never stored, logged or put in an
/// error.
enum BackupReader {
    /// Runs ADR 0002 section 5, steps 1 to 6, in order, and stops at the first failure.
    ///
    /// Synchronous and CPU bound: `EncryptedBackupService` calls it off the main actor.
    /// - Throws: `BackupError` as mapped by the ADR; `BackupImportError.keyDerivationFailed` when
    ///   CommonCrypto fails; the error of opening or reading the file, unchanged.
    static func read(
        from url: URL,
        password: String,
        deriveKey: (String, Data, UInt32) throws -> SymmetricKey
    ) throws -> BackupPayload {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // 1. Magic and version only.
        let start = [UInt8](try handle.read(upToCount: BackupFormat.firstReadLength) ?? Data())
        guard start.count == BackupFormat.firstReadLength,
              Data(start[0..<BackupFormat.magic.count]) == BackupFormat.magic
        else {
            throw BackupError.corruptedFile
        }

        // 2. Version, before anything else is checked: a newer file never reaches the KDF.
        let version = UInt16(start[8]) << 8 | UInt16(start[9])
        guard version != 0 else { throw BackupError.corruptedFile }
        guard version <= BackupFormat.version else { throw BackupError.unsupportedVersion }

        // 3. Size cap, before the rest of the file is read.
        let size = try handle.seekToEnd()
        guard size <= UInt64(BackupFormat.maxBackupFileSize) else { throw BackupError.corruptedFile }

        // 4. Whole file, bounded, so a file that grew after step 3 is never read whole. Every check
        //    runs on the bytes actually read.
        try handle.seek(toOffset: 0)
        let bytes = [UInt8](try handle.read(upToCount: BackupFormat.maxBackupFileSize + 1) ?? Data())
        guard bytes.count <= BackupFormat.maxBackupFileSize, bytes.count >= 16 else {
            throw BackupError.corruptedFile
        }
        let iterations = bigEndian(bytes[11..<15])
        let saltLength = Int(bytes[15])
        guard bytes[10] == BackupFormat.kdfID,
              BackupFormat.importIterationRange.contains(iterations),
              BackupFormat.importSaltLengthRange.contains(saltLength)
        else {
            throw BackupError.corruptedFile
        }
        let headerLength = BackupFormat.headerLength(saltLength: saltLength)
        guard bytes.count >= headerLength, bytes[16 + saltLength] == BackupFormat.cipherID else {
            throw BackupError.corruptedFile
        }
        let nonceStart = 17 + saltLength
        let lengthStart = nonceStart + BackupFormat.nonceLength
        let ciphertextLength = Int(bigEndian(bytes[lengthStart..<(lengthStart + 4)]))
        guard bytes.count == BackupFormat.fileSize(saltLength: saltLength, ciphertextLength: ciphertextLength) else {
            throw BackupError.corruptedFile
        }
        let ciphertextEnd = headerLength + ciphertextLength

        // 5. Key and authenticated decryption, the header bytes as read being the associated data.
        //    Import accepts any non-empty password (ADR 0002, section 8).
        guard !password.isEmpty else { throw BackupError.wrongPassword }
        let key: SymmetricKey
        do {
            key = try deriveKey(password, Data(bytes[16..<(16 + saltLength)]), iterations)
        } catch BackupExportError.encryptionFailed {
            throw BackupImportError.keyDerivationFailed
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(bytes[nonceStart..<lengthStart])),
                ciphertext: Data(bytes[headerLength..<ciphertextEnd]),
                tag: Data(bytes[ciphertextEnd...])
            )
            plaintext = try AES.GCM.open(box, using: key, authenticating: Data(bytes[0..<headerLength]))
        } catch {
            // AES-GCM cannot tell a wrong password from altered bytes (ADR 0002, known limit).
            throw BackupError.wrongPassword
        }

        // 6. Payload.
        return try BackupPayload.decodeForImport(plaintext)
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
