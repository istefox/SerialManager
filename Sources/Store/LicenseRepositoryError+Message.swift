import Foundation

/// User-facing text for repository failures (D8, D10).
///
/// Only `.libraryUnavailable` gets a dedicated message: the library file could not be opened
/// at launch, and Try Again cannot fix that because the repository is fixed for the session.
/// `notFound` and `duplicateID` return nil and keep the generic system text.
extension LicenseRepositoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            String(localized: "SerialManager couldn't open its library file. Quit and reopen the app; if this keeps happening, check the disk.")
        case .notFound, .duplicateID:
            nil
        }
    }
}
