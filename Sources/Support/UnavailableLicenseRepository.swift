import Foundation

/// Repository used when the persistent library cannot be opened at launch (D8).
///
/// Every call throws `LicenseRepositoryError.libraryUnavailable`, so the main window shows its
/// failure state and no create, update or delete is accepted and then lost.
struct UnavailableLicenseRepository: LicenseRepository {
    func fetchAll() async throws -> [LicenseSummary] {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func create(_ draft: LicenseDraft) async throws -> LicenseSummary {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func delete(id: UUID) async throws {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func serial(for id: UUID) async throws -> String? {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func importLicense(
        _ license: LicenseSummary,
        serial: String?,
        attachments: [AttachmentImport],
        policy: ConflictPolicy
    ) async throws -> LicenseImportOutcome {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func addAttachment(_ file: AttachmentFile, to licenseID: UUID) async throws -> LicenseSummary {
        throw LicenseRepositoryError.libraryUnavailable
    }

    func removeAttachment(id: UUID) async throws -> LicenseSummary {
        throw LicenseRepositoryError.libraryUnavailable
    }

    /// No library, so nothing is readable. The view shows the unavailable-library state anyway.
    func attachmentIsReadable(id: UUID) async -> Bool { false }

    func attachmentData(id: UUID) async throws -> Data {
        throw LicenseRepositoryError.libraryUnavailable
    }
}
