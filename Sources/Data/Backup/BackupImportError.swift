import Foundation

/// Failures of an import that are not a `BackupError` (docs/plans/0010-encrypted-import-plan.md, 2.5).
///
/// Never carries the password, the key, the payload or a serial.
enum BackupImportError: Error, Equatable, Sendable {
    /// `applyImport` without a matching pending payload (R11, also after `cancelImport()`, R17).
    /// No dedicated message.
    case noPendingImport
    /// CommonCrypto failed while deriving the key (system failure). No dedicated message.
    case keyDerivationFailed
    /// A write failed on one license; the licenses written before it stay written (D1).
    /// `underlyingMessage` is the failing error's `localizedDescription`.
    case interrupted(imported: Int, replaced: Int, underlyingMessage: String)
}

extension BackupImportError: LocalizedError {
    /// Only `interrupted` has a message. The other cases show the generic system text, as every
    /// error without a dedicated message does (docs/design/gui.md, Known gaps).
    var errorDescription: String? {
        switch self {
        case .interrupted(let imported, let replaced, let underlyingMessage):
            String(localized: "The import stopped. Imported: \(imported). Replaced: \(replaced).")
                + " " + underlyingMessage
        case .noPendingImport, .keyDerivationFailed:
            nil
        }
    }
}
