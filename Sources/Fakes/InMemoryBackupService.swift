import Foundation

/// Scripted `BackupService` for previews and tests: no file is read or written.
actor InMemoryBackupService: BackupService {
    /// Password the fake accepts; any other one fails with `.wrongPassword`.
    static let samplePassword = "test-password"

    private let repository: InMemoryLicenseRepository
    private var importLicenseCount: Int
    private var importConflicts: Set<UUID>
    private var importError: BackupError?

    init(
        repository: InMemoryLicenseRepository,
        importLicenseCount: Int = 3,
        importConflicts: Set<UUID> = [],
        importError: BackupError? = nil
    ) {
        self.repository = repository
        self.importLicenseCount = importLicenseCount
        self.importConflicts = importConflicts
        self.importError = importError
    }

    func export(to url: URL, password: String) async throws -> ExportSummary {
        let licenses = try await repository.fetchAll()
        var missing = 0
        for license in licenses where try await repository.serial(for: license.id) == nil {
            missing += 1
        }
        return ExportSummary(licenseCount: licenses.count, missingSerialCount: missing)
    }

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        if let importError { throw importError }
        guard password == Self.samplePassword else { throw BackupError.wrongPassword }
        return ImportPreview(fileURL: url, licenseCount: importLicenseCount, conflictingIDs: importConflicts)
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        let conflicts = preview.conflictingIDs.count
        let fresh = preview.licenseCount - conflicts
        switch policy {
        case .skip: return ImportSummary(imported: fresh, replaced: 0, skipped: conflicts)
        case .replace: return ImportSummary(imported: fresh, replaced: conflicts, skipped: 0)
        }
    }
}
