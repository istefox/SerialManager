import Foundation
import SwiftData

/// Why an `AttachmentRecord` refused a value.
enum AttachmentValidationError: Error, Equatable {
    /// The file name is empty or contains only whitespace.
    case emptyFileName
    /// The byte count is negative.
    case negativeByteCount
}

/// Metadata of one file attached to a license, persisted with SwiftData (ADR 0004).
///
/// The bytes are not stored here: they live encrypted in one file per attachment, named by `id`
/// (ADR 0004, D1). There is no SwiftData relationship to `License`: the row is keyed by
/// `licenseID`, the same keyed-by-UUID shape the Keychain already uses for serials (SPEC 0018, D6).
/// Every stored property is `private(set)`, so the only write path outside this type is the
/// throwing `init`.
@Model
final class AttachmentRecord {
    /// Stable identity, assigned once, and the name of the encrypted file on disk.
    /// Unique in the store: a second insert with the same id is merged into the existing entity
    /// (upsert), it is not rejected.
    @Attribute(.unique) private(set) var id: UUID
    /// The license this attachment belongs to. Not a SwiftData relationship on purpose (D6).
    private(set) var licenseID: UUID
    /// The original name as the user picked it. Required, never blank. Stored as given.
    private(set) var fileName: String
    /// Size of the plaintext, in bytes. The file on disk is larger: it carries the AES-GCM nonce
    /// and tag.
    private(set) var byteCount: Int
    /// The UTType identifier when the system knew one, else nil.
    private(set) var contentType: String?
    private(set) var addedAt: Date

    /// Creates an attachment row.
    ///
    /// Pass `id` and `addedAt` to restore an existing attachment (import); otherwise a new UUID
    /// and the current time are used.
    /// - Throws: `AttachmentValidationError` for a blank file name or a negative byte count.
    init(
        id: UUID = UUID(),
        licenseID: UUID,
        fileName: String,
        byteCount: Int,
        contentType: String? = nil,
        addedAt: Date = .now
    ) throws {
        try Self.validate(fileName: fileName, byteCount: byteCount)
        self.id = id
        self.licenseID = licenseID
        self.fileName = fileName
        self.byteCount = byteCount
        self.contentType = contentType
        self.addedAt = addedAt
    }

    /// True when the name is a single file name the app can safely put in a path.
    ///
    /// Not just non-blank: Open writes a decrypted copy under this very name (R19), so a name
    /// carrying a path separator or a relative component would place that copy outside the
    /// directory the app chose. A backup file is untrusted input, and the backup reader uses this
    /// same rule, so a file accepted by `prepareImport` cannot fail the check at apply.
    static func isValidFileName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard name != ".", name != ".." else { return false }
        // "/" on every path, ":" because the Finder and HFS treat it as one, and NUL because it
        // truncates a C path.
        return !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    private static func validate(fileName: String, byteCount: Int) throws {
        if !isValidFileName(fileName) { throw AttachmentValidationError.emptyFileName }
        if byteCount < 0 { throw AttachmentValidationError.negativeByteCount }
    }
}
