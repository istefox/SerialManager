import Foundation

/// Constants and header layout of backup format version 1 (docs/adr/0002-backup-format.md, section 3).
///
/// All integers are unsigned and big-endian. The header is bytes `[0, 33+S)`, where `S` is the salt
/// length: 49 bytes with the v1 defaults. Import (#10) reuses these constants.
enum BackupFormat {
    /// ASCII `SMBACKUP`.
    static let magic = Data("SMBACKUP".utf8)
    /// The format version this app writes, and the newest one it reads.
    static let version: UInt16 = 1
    /// PBKDF2-HMAC-SHA256.
    static let kdfID: UInt8 = 0x01
    /// Iteration count written by export (ADR 0002, section 1).
    static let iterations: UInt32 = 600_000
    static let saltLength = 16
    /// AES-256-GCM.
    static let cipherID: UInt8 = 0x01
    static let nonceLength = 12
    static let tagLength = 16
    /// Cap on the whole file, enforced by export and import alike: 64 MiB.
    static let maxBackupFileSize = 67_108_864

    /// Iteration counts import accepts (ADR 0002, section 4). Not injectable: tests derive at the
    /// real floor.
    static let importIterationRange: ClosedRange<UInt32> = 600_000...10_000_000
    /// Salt lengths import accepts (ADR 0002, section 4).
    static let importSaltLengthRange: ClosedRange<Int> = 16...64
    /// Bytes import reads first: magic and version (ADR 0002, section 5, step 1).
    static let firstReadLength = 10

    /// Bytes of the header that do not depend on the salt length:
    /// magic 8, version 2, KDF id 1, iterations 4, salt length 1, cipher id 1, nonce 12, length 4.
    static let fixedHeaderLength = 33

    /// Header length for a salt of `saltLength` bytes (`33+S`).
    static func headerLength(saltLength: Int) -> Int {
        fixedHeaderLength + saltLength
    }

    /// Size of the whole file (`33+S+L+16`).
    static func fileSize(saltLength: Int, ciphertextLength: Int) -> Int {
        headerLength(saltLength: saltLength) + ciphertextLength + tagLength
    }

    /// True when a file of `size` bytes is allowed: at most `maxFileSize` bytes.
    static func fitsSizeLimit(_ size: Int, maxFileSize: Int = maxBackupFileSize) -> Bool {
        size <= maxFileSize
    }

    /// Version 1 header for the given salt, nonce and ciphertext length.
    ///
    /// The caller checks the lengths: the salt must fit in one byte of length and the
    /// ciphertext length in a `UInt32`.
    static func header(salt: Data, nonce: Data, ciphertextLength: UInt32) -> Data {
        var header = Data(capacity: headerLength(saltLength: salt.count))
        header.append(magic)
        header.appendBigEndian(version)
        header.append(kdfID)
        header.appendBigEndian(iterations)
        header.append(UInt8(salt.count))
        header.append(salt)
        header.append(cipherID)
        header.append(nonce)
        header.appendBigEndian(ciphertextLength)
        return header
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
