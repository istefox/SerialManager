import Foundation

// Contract between the GUI and the data layer (see docs/design/gui.md).
// The data layer maps its SwiftData model and Keychain items to these types.

/// Read-only copy of one attachment, without its bytes (SPEC 0018, R11).
///
/// The sidebar and the detail view render a license from these alone, so showing a list of
/// attachments never decrypts anything and never reaches the Keychain.
struct AttachmentSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The original name as the user picked it. Never blank.
    var fileName: String
    /// Size of the plaintext, in bytes.
    var byteCount: Int
    /// UTType identifier when the system knew one.
    var contentType: String?
    var addedAt: Date
}

/// A file being attached to a license: bytes included, identity not yet assigned.
struct AttachmentFile: Equatable, Sendable {
    var fileName: String
    var contentType: String?
    var data: Data

    var byteCount: Int { data.count }
}

/// One attachment read from a backup: identity, dates and bytes all come from the file
/// (SPEC 0018, R23). An import keeps them exactly as given (R25).
struct AttachmentImport: Equatable, Sendable {
    var id: UUID
    var fileName: String
    var contentType: String?
    var addedAt: Date
    var data: Data

    var byteCount: Int { data.count }
}

/// Read-only copy of one license, without the serial.
struct LicenseSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var productName: String
    var vendor: String
    /// Name of the person the license is registered to. `""` means not set.
    var registeredName: String
    var registeredEmail: String
    var purchaseDate: Date?
    var version: String
    var notes: String
    let createdAt: Date
    var updatedAt: Date
    /// The license's attachments, ordered by `addedAt` then `fileName` (R11). Never carries bytes.
    /// Defaults to none, so a caller that does not know about attachments still compiles.
    var attachments: [AttachmentSummary] = []

    /// Plaintext bytes of every attachment of this license, for the per-license limit of D3.
    var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.byteCount } }
}

/// What the license form edits; includes the serial.
struct LicenseDraft: Equatable, Sendable {
    var productName = ""
    var vendor = ""
    /// Name of the person the license is registered to. `""` means not set.
    var registeredName = ""
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
        copy.registeredName = registeredName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            registeredName: license.registeredName,
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
    ///
    /// Attachments merge by id and are never deleted (SPEC 0018, D12 and R25): an id absent locally
    /// is added with its bytes, an id already present locally is left alone, and a local attachment
    /// absent from `attachments` is kept. No size limit applies (R25): a restore must not lose data.
    /// `updatedAt` is never bumped by the attachments: the dates come from the backup.
    func importLicense(
        _ license: LicenseSummary,
        serial: String?,
        attachments: [AttachmentImport],
        policy: ConflictPolicy
    ) async throws -> LicenseImportOutcome

    /// Attaches `file` to the license and returns the license as it now is, with `updatedAt`
    /// bumped (SPEC 0018, D9) and `attachments` including the new row.
    ///
    /// One attachment is one unit (R12): the encrypted file is written first, then the metadata
    /// row; a failure after the file was written deletes that file before the error is thrown, so
    /// no metadata row ever points at a missing file.
    /// - Throws: `AttachmentError.fileTooLarge`, `.licenseLimitExceeded` or
    ///   `.libraryLimitExceeded` when a limit of D3 or D4 is hit, with nothing written;
    ///   `LicenseRepositoryError.notFound` for an unknown license; a key error (R10).
    func addAttachment(_ file: AttachmentFile, to licenseID: UUID) async throws -> LicenseSummary

    /// Removes the attachment and its file, and returns its license with `updatedAt` bumped.
    ///
    /// Succeeds when the file is already gone, so an attachment whose file was removed behind the
    /// app's back can still be removed (R13).
    /// - Throws: `AttachmentError.notFound` when no row exists for `id`.
    func removeAttachment(id: UUID) async throws -> LicenseSummary

    /// Whether the stored file of this attachment still exists, with no decryption and no Keychain
    /// call. False means the row is an unreadable attachment: the detail view says so and still
    /// offers to remove it (SPEC 0018, R13 and R21). Never throws: a conformer that cannot tell
    /// answers true and lets the read fail with a real error.
    func attachmentIsReadable(id: UUID) async -> Bool

    /// The plaintext bytes of one attachment. Decrypts on demand: nothing else in the contract
    /// ever carries them.
    /// - Throws: `AttachmentError.notFound`, `.fileMissing`, `.decryptionFailed` or a key error.
    func attachmentData(id: UUID) async throws -> Data
}

struct ExportSummary: Equatable, Sendable {
    let licenseCount: Int
    let missingSerialCount: Int
    /// How many attachments the file carries (SPEC 0018, R26).
    let attachmentCount: Int
    /// How many attachment rows were skipped because their stored file was gone.
    ///
    /// The counterpart of `missingSerialCount`: data already lost before the export, reported so
    /// the user knows the backup does not hold it, never a reason to refuse the backup.
    let missingAttachmentCount: Int

    init(
        licenseCount: Int,
        missingSerialCount: Int,
        attachmentCount: Int = 0,
        missingAttachmentCount: Int = 0
    ) {
        self.licenseCount = licenseCount
        self.missingSerialCount = missingSerialCount
        self.attachmentCount = attachmentCount
        self.missingAttachmentCount = missingAttachmentCount
    }
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
