import Foundation
import SwiftData

/// Why a `License` refused a value.
enum LicenseValidationError: Error, Equatable {
    /// The product name is empty or contains only whitespace.
    case emptyProductName
}

/// Descriptive data of one license, persisted with SwiftData.
///
/// The serial is not stored here: it lives in the Keychain, keyed by `id` (ADR 0001).
/// Every stored property is `private(set)`, so outside this type the only write paths are
/// the throwing `init`, `update` and `restore`, which all reject a blank product name. SwiftData's
/// reflective write API on `PersistentModel` can still bypass that check; app code must
/// not use it on `License` (SPEC `docs/specs/license-model.md`, R4).
@Model
final class License {
    /// Stable identity, assigned once. Unique in the store: a second insert with the same
    /// id is merged into the existing entity (upsert), it is not rejected.
    @Attribute(.unique) private(set) var id: UUID
    /// Required, never blank. Stored as given, without trimming.
    private(set) var productName: String
    /// `""` means not set.
    private(set) var vendor: String
    /// `""` means not set.
    private(set) var registeredEmail: String
    private(set) var purchaseDate: Date?
    /// `""` means not set.
    private(set) var version: String
    /// `""` means not set.
    private(set) var notes: String
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Creates a license.
    ///
    /// Pass `id`, `createdAt` and `updatedAt` to restore an existing entry (import);
    /// otherwise a new UUID and the current time are used. `updatedAt` defaults to
    /// `createdAt`.
    /// - Throws: `LicenseValidationError.emptyProductName` for a blank product name.
    init(
        id: UUID = UUID(),
        productName: String,
        vendor: String = "",
        registeredEmail: String = "",
        purchaseDate: Date? = nil,
        version: String = "",
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) throws {
        try Self.validate(productName: productName)
        self.id = id
        self.productName = productName
        self.vendor = vendor
        self.registeredEmail = registeredEmail
        self.purchaseDate = purchaseDate
        self.version = version
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Replaces every editable field and sets `updatedAt` to `now`.
    ///
    /// Validation runs before any assignment: when it throws, no field changes,
    /// `updatedAt` included.
    /// - Throws: `LicenseValidationError.emptyProductName` for a blank product name.
    func update(
        productName: String,
        vendor: String,
        registeredEmail: String,
        purchaseDate: Date?,
        version: String,
        notes: String,
        now: Date = .now
    ) throws {
        try Self.validate(productName: productName)
        self.productName = productName
        self.vendor = vendor
        self.registeredEmail = registeredEmail
        self.purchaseDate = purchaseDate
        self.version = version
        self.notes = notes
        self.updatedAt = now
    }

    /// Replaces every field and both dates with the values of a backup.
    ///
    /// Import only: used when an import replaces an existing license (SPEC 0010, D3; license model
    /// SPEC R4 and R8). App code edits a license through `update`.
    /// Validation runs before any assignment: when it throws, no field changes, the dates included.
    /// - Throws: `LicenseValidationError.emptyProductName` for a blank product name.
    func restore(
        productName: String,
        vendor: String,
        registeredEmail: String,
        purchaseDate: Date?,
        version: String,
        notes: String,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        try Self.validate(productName: productName)
        self.productName = productName
        self.vendor = vendor
        self.registeredEmail = registeredEmail
        self.purchaseDate = purchaseDate
        self.version = version
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Same rule as `LicenseDraft.hasValidProductName`: true when the name has a character other
    /// than whitespace or a newline. The trimmed value is only tested. The backup reader uses it too,
    /// so a file accepted by `prepareImport` cannot fail this check at apply.
    static func isValidProductName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validate(productName: String) throws {
        if !isValidProductName(productName) {
            throw LicenseValidationError.emptyProductName
        }
    }
}
