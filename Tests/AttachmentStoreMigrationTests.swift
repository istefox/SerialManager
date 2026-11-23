import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// The schema migration of SPEC 0018 (R14, A13).
///
/// `AttachmentRecord` is a new entity and no property of `License` changed, so SwiftData's
/// lightweight migration opens an older store unchanged. This is the one failure of the ticket
/// that would lose the user's data, and an in-memory container cannot prove it: every test here
/// writes a real store file with a `License.self`-only container, exactly as the build before #18
/// did, then reopens that same file with the container the app now builds.
@MainActor
struct AttachmentStoreMigrationTests {
    private let t = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// A store file written by the previous build: one entity, one license, saved and closed.
    private func writeLegacyStore(at url: URL, name: String = "Sample Pro") throws -> UUID {
        let container = try ModelContainer(
            for: License.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let license = try License(
            productName: name, vendor: "Sample Vendor", registeredName: "Sample Owner",
            registeredEmail: "owner@example.invalid", purchaseDate: t, version: "1.0",
            notes: "Fake sample row.", createdAt: t, updatedAt: t)
        let id = license.id
        context.insert(license)
        try context.save()
        return id
    }

    @Test("A store written before #18 opens with the two-entity container, data intact")
    func opensLegacyStore() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Licenses.store")
        let id = try writeLegacyStore(at: url)

        // The container the app builds today, on the very file the previous build wrote.
        let migrated = try LicenseLibrary.makeContainer(at: url)
        let context = ModelContext(migrated)
        let licenses = try context.fetch(FetchDescriptor<License>())

        #expect(licenses.count == 1)
        #expect(licenses.first?.id == id)
        #expect(licenses.first?.productName == "Sample Pro")
        #expect(licenses.first?.registeredName == "Sample Owner")
        #expect(licenses.first?.createdAt == t)
        #expect(licenses.first?.updatedAt == t)
        // The new entity exists and is empty: no attachment is invented for an old license.
        #expect(try context.fetch(FetchDescriptor<AttachmentRecord>()).isEmpty)
    }

    @Test("The migrated store accepts attachments and the license survives a reopen")
    func writesAfterMigration() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Licenses.store")
        let attachmentsDirectory = try TemporaryDirectory()
        defer { attachmentsDirectory.remove() }
        let id = try writeLegacyStore(at: url)

        let keys = InMemoryAttachmentKeyStore(key: AttachmentFixtures.key())
        let repository = SwiftDataLicenseRepository(
            modelContainer: try LicenseLibrary.makeContainer(at: url),
            serials: InMemorySerialStore(),
            attachments: AttachmentFileStore(directory: attachmentsDirectory.url, keys: keys)
        )
        let saved = try await repository.addAttachment(AttachmentFixtures.file(), to: id)
        #expect(saved.attachments.count == 1)

        // Third open of the same file: the row is really on disk, next to the migrated license.
        let reopened = ModelContext(try LicenseLibrary.makeContainer(at: url))
        #expect(try reopened.fetch(FetchDescriptor<License>()).count == 1)
        let rows = try reopened.fetch(FetchDescriptor<AttachmentRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.licenseID == id)
        #expect(rows.first?.fileName == "Sample-Pro.lic")
    }
}
