import Foundation

/// Failures raised by the repository itself. Serial store and SwiftData errors are never
/// wrapped in this type: they are rethrown as they are, so the GUI sees them unchanged.
enum LicenseRepositoryError: Error, Equatable {
    /// No entry exists for this id.
    case notFound(UUID)
    /// `create` generated an id that an existing entry already uses; nothing was written.
    case duplicateID(UUID)
    /// The persistent library could not be opened at launch.
    case libraryUnavailable
}
