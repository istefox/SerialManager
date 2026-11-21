import Foundation

/// Failures of the export itself (docs/plans/0009-encrypted-export-plan.md, section 2.3).
///
/// Other errors (repository, serial store, file write) are rethrown unchanged, so the export sheet
/// shows the message the app already shows for them. No case carries the password, the key, the
/// payload or a serial.
enum BackupExportError: Error, Equatable, Sendable {
    /// The file would be larger than `BackupFormat.maxBackupFileSize`.
    case fileTooLarge
    /// Random bytes, key derivation or sealing failed (system failure, not user input).
    case encryptionFailed
}

extension BackupExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            String(localized: "The backup is larger than 64 MB, the maximum size.")
        case .encryptionFailed:
            String(localized: "The backup couldn't be encrypted. Try again.")
        }
    }
}
