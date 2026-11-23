import Foundation

/// Scripted `BackupService` for previews and tests: no file is read or written.
actor InMemoryBackupService: BackupService {
    /// Password the fake accepts; any other one fails with `.wrongPassword`.
    static let samplePassword = "test-password"

    private let repository: InMemoryLicenseRepository
    private var importLicenseCount: Int
    private var importConflicts: Set<UUID>
    private var importError: BackupError?
    /// File of the last successful `prepareImport`, nil once cancelled (R17). The fake keeps it after
    /// an apply: single use (R11) is modelled by the real service only.
    private var pendingURL: URL?

    /// Error of `applyImport` when no matching import is pending. No dedicated message: like the real
    /// service's `noPendingImport` (plan 0010, 2.5), it shows the generic system text.
    private struct NoPendingImport: Error {}

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
        return ExportSummary(
            licenseCount: licenses.count,
            missingSerialCount: missing,
            attachmentCount: licenses.reduce(0) { $0 + $1.attachments.count })
    }

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        pendingURL = nil
        if let importError { throw importError }
        guard password == Self.samplePassword else { throw BackupError.wrongPassword }
        pendingURL = url
        return ImportPreview(fileURL: url, licenseCount: importLicenseCount, conflictingIDs: importConflicts)
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        guard let pendingURL, pendingURL == preview.fileURL else { throw NoPendingImport() }
        let conflicts = preview.conflictingIDs.count
        let fresh = preview.licenseCount - conflicts
        switch policy {
        case .skip: return ImportSummary(imported: fresh, replaced: 0, skipped: conflicts)
        case .replace: return ImportSummary(imported: fresh, replaced: conflicts, skipped: 0)
        }
    }

    func cancelImport() {
        pendingURL = nil
    }
}
