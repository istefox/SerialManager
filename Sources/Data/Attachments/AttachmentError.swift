import Foundation

/// Failures of the attachment layer (SPEC 0018, R21).
///
/// No case carries the library key, the plaintext bytes or a serial: a file name and a limit are
/// the only values a message shows.
enum AttachmentError: Error, Equatable, Sendable {
    /// The file is larger than `AttachmentLimits.maxFileBytes`.
    case fileTooLarge(fileName: String, limit: Int)
    /// This license already holds `AttachmentLimits.maxLicenseBytes` or would exceed it.
    case licenseLimitExceeded(fileName: String, limit: Int)
    /// The library already holds `AttachmentLimits.maxLibraryBytes` or would exceed it.
    case libraryLimitExceeded(fileName: String, limit: Int)
    /// No attachment row exists for this id.
    case notFound(UUID)
    /// The row exists but its file is gone: shown as an unreadable attachment, removable (R13).
    case fileMissing(UUID)
    /// The stored bytes did not authenticate under the library key, or are not a sealed box.
    case decryptionFailed
    /// The library key could not be encrypted or sealed (system failure).
    case encryptionFailed
    /// The Keychain holds no key item and the library holds attachments, so a new key must not be
    /// generated: generating one would make every stored file permanently unreadable (R10).
    case keyMissing
    /// The user or the system refused access to the key item. Never generates a key (R10).
    case keyAccessDenied
    /// The key item exists but is not 32 bytes. Never replaced (R10).
    case keyUndecodable
    /// Any other Keychain failure, with the status code. Never generates a key (R10).
    case keyUnexpected(status: OSStatus)
    /// The decrypted copy was written but no application would open it (R19).
    case openFailed(fileName: String)
}

extension AttachmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let fileName, let limit):
            String(localized: "“\(fileName)” is larger than \(AttachmentLimits.formatted(limit)), the maximum size of one attachment.")
        case .licenseLimitExceeded(let fileName, let limit):
            String(localized: "Adding “\(fileName)” would take this license over \(AttachmentLimits.formatted(limit)) of attachments, its maximum.")
        case .libraryLimitExceeded(let fileName, let limit):
            String(localized: "Adding “\(fileName)” would take your library over \(AttachmentLimits.formatted(limit)) of attachments in total, the maximum that still fits in a backup.")
        case .notFound:
            String(localized: "This attachment is no longer in your library.")
        case .fileMissing:
            String(localized: "The file of this attachment is missing, so it can't be opened. You can remove it and add the file again.")
        case .decryptionFailed:
            String(localized: "This attachment couldn't be decrypted. Its file may be damaged.")
        case .encryptionFailed:
            String(localized: "This attachment couldn't be encrypted. Try again.")
        case .keyMissing:
            String(localized: "The key that protects your attachments is missing from the Keychain, so they can't be read. Restore a backup of your Keychain, or import a SerialManager backup.")
        case .keyAccessDenied:
            String(localized: "SerialManager couldn't reach the key that protects your attachments. Allow access when macOS asks, then try again.")
        case .keyUndecodable:
            String(localized: "The key that protects your attachments is stored in a form SerialManager doesn't recognize.")
        case .keyUnexpected:
            String(localized: "The key that protects your attachments couldn't be read from the Keychain.")
        case .openFailed(let fileName):
            String(localized: "macOS found no application to open “\(fileName)”. Use Save a Copy and open it yourself.")
        }
    }
}
