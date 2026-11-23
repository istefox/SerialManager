import Foundation
import SwiftData

/// Where the persistent library lives and how the app opens it (plan 0004, section 2.7).
///
/// Compiled in every configuration so Debug tests cover it, though only Release builds call
/// `makeRepository()` with its defaults.
enum LicenseLibrary {
    /// The app's own folder in Application Support. Not coupled to the Keychain service name.
    static let folderName = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"

    /// `Application Support/<folderName>/Licenses.store`. The SwiftData default
    /// (`Application Support/default.store`) is shared by every non-sandboxed app, so it is not used.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory
            .appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: "Licenses.store", directoryHint: .notDirectory)
    }

    /// `Application Support/<folderName>/Attachments`, one encrypted file per attachment
    /// (ADR 0004). Separate from the store file so a store copy never carries the blobs.
    static var defaultAttachmentsDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// Creates the parent directory if needed, then opens a persistent container for `License`
    /// and `AttachmentRecord`.
    static func makeContainer(at url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Explicitly local: the app has no CloudKit entitlement, and the library must not start
        // syncing if one is ever added for another reason.
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        // Adding `AttachmentRecord` to the container is a lightweight migration: no property of
        // `License` changed, so a store written before #18 opens unchanged (SPEC 0018, R14).
        return try ModelContainer(
            for: License.self, AttachmentRecord.self, configurations: configuration)
    }

    /// The real repository, or `UnavailableLicenseRepository` when the library cannot be opened.
    /// Never falls back to an in-memory store, which would silently discard what the user types (D8).
    static func makeRepository(
        at url: URL = defaultStoreURL,
        serials: any SerialStore = KeychainSerialStore(),
        attachments: AttachmentFileStore = AttachmentFileStore(
            directory: defaultAttachmentsDirectory, keys: KeychainAttachmentKeyStore())
    ) -> any LicenseRepository {
        do {
            return SwiftDataLicenseRepository(
                modelContainer: try makeContainer(at: url),
                serials: serials,
                attachments: attachments
            )
        } catch {
            return UnavailableLicenseRepository()
        }
    }
}
