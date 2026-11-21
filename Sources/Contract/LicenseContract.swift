import Foundation

// Contract between the GUI and the data layer (see docs/design/gui.md).
// The data layer maps its SwiftData model and Keychain items to these types.

/// Read-only copy of one license, without the serial.
struct LicenseSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var productName: String
    var vendor: String
    var registeredEmail: String
    var purchaseDate: Date?
    var version: String
    var notes: String
    let createdAt: Date
    var updatedAt: Date
}

/// What the license form edits; includes the serial.
struct LicenseDraft: Equatable, Sendable {
    var productName = ""
    var vendor = ""
    var registeredEmail = ""
    var purchaseDate: Date?
    var version = ""
    var notes = ""
    var serial = ""

    /// True when the product name has visible characters.
    var hasValidProductName: Bool {
        !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Copy with surrounding whitespace removed from every single-line field.
    var normalized: LicenseDraft {
        var copy = self
        copy.productName = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.vendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.registeredEmail = registeredEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

extension LicenseDraft {
    /// Draft prefilled from an existing license and its serial (nil when missing).
    init(_ license: LicenseSummary, serial: String?) {
        self.init(
            productName: license.productName,
            vendor: license.vendor,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            serial: serial ?? ""
        )
    }
}

/// What `LicenseRepository.importLicense` did with one license of a backup.
enum LicenseImportOutcome: Equatable, Sendable {
    case created
    case replaced
    case skipped
}

protocol LicenseRepository: Sendable {
    func fetchAll() async throws -> [LicenseSummary]
    func create(_ draft: LicenseDraft) async throws -> LicenseSummary
    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary
    func delete(id: UUID) async throws
    /// Returns nil when the Keychain item for this license is missing.
    func serial(for id: UUID) async throws -> String?
    /// Writes one license read from a backup, keeping its `id`, fields, `createdAt` and `updatedAt`
    /// exactly as given (SPEC 0010, D3). Looks `license.id` up first and never relies on the
    /// SwiftData upsert.
    /// - No license with this id: creates it; `serial` non-nil and non-empty is saved, otherwise no
    ///   Keychain item is written. Returns `.created`.
    /// - Existing id, `.skip`: changes nothing, makes no serial store call. Returns `.skipped`.
    /// - Existing id, `.replace`: replaces every field and both dates; the serial is replaced when
    ///   non-nil and non-empty, kept otherwise. Returns `.replaced`.
    /// Never removes a Keychain item that existed before the call. One license is one unit (D4): on
    /// failure the call leaves no change of its own, except the documented compensation residue.
    func importLicense(_ license: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome
}

struct ExportSummary: Equatable, Sendable {
    let licenseCount: Int
    let missingSerialCount: Int
}

/// A decrypted backup, ready to be applied.
struct ImportPreview: Equatable, Sendable {
    let fileURL: URL
    let licenseCount: Int
    let conflictingIDs: Set<UUID>
}

enum ConflictPolicy: Sendable {
    case skip
    case replace
}

struct ImportSummary: Equatable, Sendable {
    let imported: Int
    let replaced: Int
    let skipped: Int
}

enum BackupError: Error, Equatable {
    case wrongPassword
    case corruptedFile
    case unsupportedVersion
}

protocol BackupService: Sendable {
    /// False while the File menu must keep Export disabled for this service.
    var isExportAvailable: Bool { get }
    /// False while the File menu must keep Import disabled for this service.
    var isImportAvailable: Bool { get }
    func export(to url: URL, password: String) async throws -> ExportSummary
    func prepareImport(from url: URL, password: String) async throws -> ImportPreview
    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary
    /// Drops the payload kept by `prepareImport`, if any (D5, R17). Idempotent, never throws, writes
    /// nothing to the library or the Keychain, safe with no import in progress. After it, `applyImport`
    /// with an earlier preview fails as in R11. A `prepareImport` running when this is called leaves no
    /// pending payload once it returns. Does not stop or change an `applyImport` already running.
    ///
    /// No default implementation on purpose: a default no-op would let a conformer that keeps a
    /// payload compile without dropping it.
    func cancelImport() async
}

extension BackupService {
    var isExportAvailable: Bool { true }
    var isImportAvailable: Bool { true }
}
