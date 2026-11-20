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
}
