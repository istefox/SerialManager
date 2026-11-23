import Foundation

/// The size limits of SPEC 0018, D3 and D4, in decimal bytes as the Finder counts them, measured
/// on the plaintext.
///
/// One place for the data layer and the form alike: the form refuses a file the moment it is
/// picked (R16), and the repository refuses it again when it writes, so a path that skips the
/// form cannot exceed a limit.
enum AttachmentLimits {
    /// 5,000,000 bytes per file (D3).
    static let maxFileBytes = 5_000_000
    /// 20,000,000 bytes of attachments per license (D3).
    static let maxLicenseBytes = 20_000_000
    /// 40,000,000 bytes of attachments in the whole library (D4). Keeps a normal library inside
    /// the 64 MiB backup cap once base64 has inflated it by 4/3.
    static let maxLibraryBytes = 40_000_000

    /// Checks one new file against the three limits, in order: per file, per license, per library.
    ///
    /// - Parameters:
    ///   - byteCount: plaintext size of the file being added.
    ///   - fileName: the name to put in the error, so the message can say which file was refused.
    ///   - licenseBytes: plaintext bytes already attached to the same license.
    ///   - libraryBytes: plaintext bytes already attached anywhere in the library.
    /// - Throws: `AttachmentError.fileTooLarge`, `.licenseLimitExceeded` or
    ///   `.libraryLimitExceeded`. Never thrown by an import (D12, R25): an import does not call this.
    static func check(
        byteCount: Int,
        fileName: String,
        licenseBytes: Int,
        libraryBytes: Int
    ) throws {
        if byteCount > maxFileBytes {
            throw AttachmentError.fileTooLarge(fileName: fileName, limit: maxFileBytes)
        }
        if licenseBytes + byteCount > maxLicenseBytes {
            throw AttachmentError.licenseLimitExceeded(fileName: fileName, limit: maxLicenseBytes)
        }
        if libraryBytes + byteCount > maxLibraryBytes {
            throw AttachmentError.libraryLimitExceeded(fileName: fileName, limit: maxLibraryBytes)
        }
    }

    /// The limits formatted the way the messages show them ("5 MB"), from the byte count, so the
    /// number in a message can never drift from the constant it describes.
    static func formatted(_ bytes: Int) -> String {
        ByteCountFormatStyle(style: .file, allowedUnits: [.mb, .kb, .bytes]).format(Int64(bytes))
    }
}
