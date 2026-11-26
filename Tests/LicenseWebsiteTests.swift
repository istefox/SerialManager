import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// The optional "Web" field of a license (SPEC `docs/specs/0030-license-website-favicon.md`).
///
/// Covers normalization (D2), the form (A1 to A3), the SwiftData store on disk and its migration
/// from a store written before the field existed (A1, A4) and the backup (A5). No test touches the
/// real Keychain or the owner's library. Sample values are fake.
/// The `License` entity as the previous build declared it: no `website`. A nested type keeps the
/// entity name `License`, which is what makes the store file look like one written by the old
/// build. File scope and internal, because the `@Model` expansion cannot see a private type.
enum PreWebsiteSchema {
    @Model
    final class License {
        @Attribute(.unique) var id: UUID
        var productName: String
        var vendor: String
        var registeredName: String = ""
        var registeredEmail: String
        var purchaseDate: Date?
        var version: String
        var notes: String
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID, productName: String, createdAt: Date) {
            self.id = id
            self.productName = productName
            self.vendor = "Sample Vendor"
            self.registeredEmail = "owner@example.invalid"
            self.purchaseDate = nil
            self.version = "1.0"
            self.notes = "Fake sample row."
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    /// The second entity of the baseline schema (`LicenseLibrary.makeContainer` before this change),
    /// keyed to its license by `licenseID`, with no SwiftData relationship.
    @Model
    final class AttachmentRecord {
        @Attribute(.unique) var id: UUID
        var licenseID: UUID
        var fileName: String
        var byteCount: Int
        var contentType: String?
        var addedAt: Date

        init(id: UUID, licenseID: UUID, fileName: String, byteCount: Int, addedAt: Date) {
            self.id = id
            self.licenseID = licenseID
            self.fileName = fileName
            self.byteCount = byteCount
            self.contentType = "public.plain-text"
            self.addedAt = addedAt
        }
    }
}

/// Addresses the Web field must refuse. File scope, so the `@Test` arguments do not touch a
/// main-actor-isolated property.
private let invalidWebsiteInputs = [
    "ftp://example.test",
    "not a url with spaces",
    "https://exa mple.test",
    "http://",
    "https://",
    "file:///etc/hosts",
    "mailto:123",
    "javascript:alert(1)",
]

@MainActor
struct LicenseWebsiteTests {
    private let serial = "FAKE-0000-TEST"

    // MARK: Normalization (D2)

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com  ", "https://example.com"),
        ("https://example.com", "https://example.com"),
        ("http://example.test/products?id=1", "http://example.test/products?id=1"),
        ("example.test:8080/app", "https://example.test:8080/app"),
        ("example.com/help?source=https://example.net", "https://example.com/help?source=https://example.net"),
        ("HTTP://Example.test", "HTTP://Example.test"),
        ("", ""),
        ("   \n", ""),
    ])
    func normalizesValidInput(input: String, expected: String) {
        #expect(WebsiteURL.normalize(input) == expected)
    }

    @Test(arguments: invalidWebsiteInputs)
    func rejectsInvalidInput(_ input: String) {
        #expect(WebsiteURL.normalize(input) == nil)
        #expect(!LicenseDraft(productName: "Example App", website: input).hasValidWebsite)
    }

    // MARK: A1, form and model

    private func makeInMemoryStore() -> LicenseStore {
        LicenseStore(repository: InMemoryLicenseRepository(entries: []), initial: [])
    }

    @Test func formStoresTheNormalizedAddressAndEditShowsIt() async throws {
        let store = makeInMemoryStore()
        let model = LicenseFormModel()
        model.draft = LicenseDraft(productName: "Example App", website: " example.com ", serial: serial)

        #expect(model.websiteIsValid)
        #expect(await model.save(to: store))

        let saved = try #require(store.licenses.first)
        #expect(saved.website == "https://example.com")
        // The form keeps showing what is stored, so Cancel sees no phantom change.
        #expect(model.draft.website == "https://example.com")
        #expect(!model.hasChanges)

        let edit = LicenseFormModel(license: saved)
        #expect(edit.draft.website == "https://example.com")
    }

    @Test func websiteIsOptional() async throws {
        let store = makeInMemoryStore()
        let model = LicenseFormModel()
        model.draft = LicenseDraft(productName: "Example App", serial: serial)

        #expect(await model.save(to: store))
        #expect(store.licenses.first?.website == "")
    }

    // MARK: A1, on-disk store closed and reopened

    private func makeRepository(_ container: ModelContainer) -> SwiftDataLicenseRepository {
        SwiftDataLicenseRepository(
            modelContainer: container, serials: InMemorySerialStore(), attachments: .unusedForTests())
    }

    @Test func websiteSurvivesClosingAndReopeningTheStore() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Licenses.store")

        do {
            let container = try LicenseLibrary.makeContainer(at: url)
            let store = LicenseStore(repository: makeRepository(container))
            let model = LicenseFormModel()
            model.draft = LicenseDraft(productName: "Example App", website: "example.com", serial: serial)
            #expect(await model.save(to: store))
        }

        let reopened = try LicenseLibrary.makeContainer(at: url)
        let licenses = try await makeRepository(reopened).fetchAll()
        let stored = try #require(licenses.first)
        #expect(licenses.count == 1)
        #expect(stored.website == "https://example.com")
        #expect(LicenseFormModel(license: stored).draft.website == "https://example.com")
    }

    // MARK: A2, clearing

    @Test func clearingTheFieldStoresAnEmptyString() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Licenses.store")
        let container = try LicenseLibrary.makeContainer(at: url)
        let store = LicenseStore(repository: makeRepository(container))

        let new = LicenseFormModel()
        new.draft = LicenseDraft(productName: "Example App", website: "example.com", serial: serial)
        #expect(await new.save(to: store))
        let stored = try #require(store.licenses.first)
        #expect(stored.website == "https://example.com")

        let clearing = LicenseFormModel(license: stored, draft: LicenseDraft(stored, serial: serial))
        clearing.draft.website = "   "
        #expect(await clearing.save(to: store))

        let reopened = try LicenseLibrary.makeContainer(at: url)
        let after = try #require(try await makeRepository(reopened).fetchAll().first)
        #expect(after.website == "")
        #expect(store.licenses.first?.website == "")
    }

    // MARK: A3, invalid input

    @Test(arguments: invalidWebsiteInputs)
    func invalidWebsiteBlocksSave(_ input: String) async throws {
        let store = makeInMemoryStore()
        let model = LicenseFormModel()
        model.draft = LicenseDraft(productName: "Example App", website: input, serial: serial)

        // The view shows the message and disables Save on `websiteIsValid`; `save` refuses as well.
        #expect(!model.websiteIsValid)
        #expect(await model.save(to: store) == false)
        #expect(store.licenses.isEmpty)

        model.draft.website = "example.com"
        #expect(model.websiteIsValid)
        #expect(await model.save(to: store))
    }

    // MARK: Model

    @Test func modelStoresAndUpdatesWebsite() throws {
        let container = try ModelContainer(
            for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let license = try License(productName: "Example App", website: "https://example.test")
        container.mainContext.insert(license)
        #expect(license.website == "https://example.test")
        #expect(try License(productName: "Other").website == "")

        try license.update(
            productName: "Example App", vendor: "", registeredName: "", registeredEmail: "",
            website: "", purchaseDate: nil, version: "", notes: "")
        #expect(license.website == "")
    }

    // MARK: A4, migration from the schema written before the field existed

    @Test func storeWrittenBeforeTheFieldOpensWithAnEmptyWebsite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Licenses.store")
        let created = Date(timeIntervalSinceReferenceDate: 790_000_000)
        let ids = [UUID(), UUID(), UUID()]
        let attachmentID = UUID()

        do {
            // Both baseline entities, as the previous build's container declared them.
            let legacy = try ModelContainer(
                for: PreWebsiteSchema.License.self, PreWebsiteSchema.AttachmentRecord.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = ModelContext(legacy)
            for (index, id) in ids.enumerated() {
                context.insert(PreWebsiteSchema.License(id: id, productName: "Old App \(index)", createdAt: created))
            }
            context.insert(PreWebsiteSchema.AttachmentRecord(
                id: attachmentID, licenseID: ids[1], fileName: "receipt.txt", byteCount: 42, addedAt: created))
            try context.save()
        }

        let migrated = try LicenseLibrary.makeContainer(at: url)
        let licenses = try await makeRepository(migrated).fetchAll()

        #expect(Set(licenses.map(\.id)) == Set(ids))
        #expect(licenses.count == 3)
        #expect(licenses.allSatisfy { $0.website == "" })
        #expect(licenses.allSatisfy { $0.vendor == "Sample Vendor" && $0.createdAt == created })

        // The attachment row survives and still points at its license.
        let attachments = try ModelContext(migrated).fetch(FetchDescriptor<AttachmentRecord>())
        #expect(attachments.count == 1)
        let attachment = try #require(attachments.first)
        #expect(attachment.id == attachmentID)
        #expect(attachment.licenseID == ids[1])
        #expect(attachment.fileName == "receipt.txt" && attachment.byteCount == 42)
        #expect(licenses.contains { $0.id == attachment.licenseID })

        // The migrated store accepts a website on an old license.
        let repository = makeRepository(migrated)
        let first = try #require(licenses.first)
        var draft = LicenseDraft(first, serial: nil)
        draft.website = "https://example.test"
        draft.leavesSerialUntouched = true
        _ = try await repository.update(id: first.id, with: draft)
        let again = try await makeRepository(try LicenseLibrary.makeContainer(at: url)).fetchAll()
        #expect(again.first { $0.id == first.id }?.website == "https://example.test")
    }

    // MARK: A5, backup

    private func payloadEntry(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> BackupPayload.Entry {
        var entry = BackupPayloadJSON.entry()
        change(&entry)
        let data = try BackupPayloadJSON.payload(entries: [entry])
        return try #require(try BackupPayload.decodeForImport(data).licenses.first)
    }

    @Test func entryWithoutTheKeyDecodesAsEmpty() throws {
        let entry = try payloadEntry { $0.removeValue(forKey: "website") }
        #expect(entry.website == "")
    }

    @Test func entryWithTheKeyDecodesIt() throws {
        let entry = try payloadEntry { $0["website"] = "https://example.test" }
        #expect(entry.website == "https://example.test")
    }

    @Test func exportAlwaysWritesTheKey() throws {
        for website in ["", "https://example.test"] {
            var license = BackupFixtures.editor
            license.website = website
            let data = try BackupPayload.makeEncoder().encode(
                BackupPayload(exportedAt: BackupFixtures.exportedAt, licenses: [BackupPayload.Entry(license, serial: nil)]))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entry = try #require((root["licenses"] as? [[String: Any]])?.first)
            #expect(entry["website"] as? String == website)
        }
    }

    @Test func exportThenImportRoundTripsTheWebsite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = makeRepository(try ModelContainer(
            for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        _ = try await source.create(LicenseDraft(productName: "With Site", website: "https://example.test", serial: "FAKE-1"))
        _ = try await source.create(LicenseDraft(productName: "Without Site", serial: "FAKE-2"))
        let url = directory.file()
        _ = try await EncryptedBackupService(repository: source).export(to: url, password: BackupFixtures.password)

        let target = makeRepository(try ModelContainer(
            for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let service = EncryptedBackupService(repository: target)
        let preview = try await service.prepareImport(from: url, password: BackupFixtures.password)
        _ = try await service.applyImport(preview, policy: .skip)

        let imported = try await target.fetchAll()
        #expect(imported.count == 2)
        #expect(imported.first { $0.productName == "With Site" }?.website == "https://example.test")
        #expect(imported.first { $0.productName == "Without Site" }?.website == "")
    }

    @Test func fileWrittenBeforeTheFieldStillImports() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()
        try BackupImportFixture.data.write(to: url)

        let target = makeRepository(try ModelContainer(
            for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let service = BackupFixtures.service(repository: target)
        let preview = try await service.prepareImport(from: url, password: BackupFixtures.password)
        _ = try await service.applyImport(preview, policy: .skip)

        let imported = try await target.fetchAll()
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.website == "" })
    }
}
