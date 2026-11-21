import Foundation

/// Backup service used by release builds until the real encrypted backup lands.
/// It never writes or reads a file and always fails, so the app can't report a backup that
/// doesn't exist. The File menu disables Import and Export when this service is in use.
struct UnavailableBackupService: BackupService {
    struct NotAvailable: LocalizedError, Equatable {
        var errorDescription: String? {
            String(localized: "Backup isn't available yet in this version of SerialManager.")
        }
    }

    var isExportAvailable: Bool { false }
    var isImportAvailable: Bool { false }

    func export(to url: URL, password: String) async throws -> ExportSummary {
        throw NotAvailable()
    }

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        throw NotAvailable()
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        throw NotAvailable()
    }
}
