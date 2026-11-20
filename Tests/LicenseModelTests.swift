import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Tests for the SwiftData `License` model on an in-memory store.
/// Writes go through `container.mainContext`; reads go through a new `ModelContext`
/// after `save()`, so they hit the store and not the in-memory object graph.
@MainActor
struct LicenseModelTests {
    private let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var tPlus1: Date { t.addingTimeInterval(60) }

    /// The nine stored fields, compared as a value.
    private struct Snapshot: Equatable {
        let id: UUID
        let productName: String
        let vendor: String
        let registeredEmail: String
        let purchaseDate: Date?
        let version: String
        let notes: String
        let createdAt: Date
        let updatedAt: Date

        init(_ license: License) {
            id = license.id
            productName = license.productName
            vendor = license.vendor
            registeredEmail = license.registeredEmail
            purchaseDate = license.purchaseDate
            version = license.version
            notes = license.notes
            createdAt = license.createdAt
            updatedAt = license.updatedAt
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: License.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Fetches by id in a new context and copies the values while that context is alive,
    /// so no assertion reads a model whose context has been released.
    private func fetch(_ id: UUID, in container: ModelContainer) throws -> [Snapshot] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<License>(predicate: #Predicate { $0.id == id }))
            .map(Snapshot.init)
    }

    private func count(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<License>())
    }

    /// Inserts and saves the A1 entity: "Example App" by "Acme Corp" at `t`.
    private func insertExample(in container: ModelContainer) throws -> License {
        let license = try License(productName: "Example App", vendor: "Acme Corp", createdAt: t)
        container.mainContext.insert(license)
        try container.mainContext.save()
        return license
    }

    @Test func createStoresDefaults() throws {
        let container = try makeContainer()
        let license = try insertExample(in: container)

        let fetched = try #require(try fetch(license.id, in: container).first)
        #expect(fetched.productName == "Example App")
        #expect(fetched.vendor == "Acme Corp")
        #expect(fetched.registeredEmail == "")
        #expect(fetched.version == "")
        #expect(fetched.notes == "")
        #expect(fetched.purchaseDate == nil)
        #expect(fetched.createdAt == t)
        #expect(fetched.updatedAt == t)
    }

    @Test func createKeepsSuppliedIdentityAndDates() throws {
        let container = try makeContainer()
        let id = UUID()
        let created = t.addingTimeInterval(-86_400)
        let license = try License(
            id: id,
            productName: "Example App",
            registeredEmail: "user@example.com",
            purchaseDate: created,
            createdAt: created,
            updatedAt: t
        )
        container.mainContext.insert(license)
        try container.mainContext.save()

        let fetched = try #require(try fetch(id, in: container).first)
        #expect(fetched.id == id)
        #expect(fetched.createdAt == created)
        #expect(fetched.updatedAt == t)
        #expect(fetched.registeredEmail == "user@example.com")
        #expect(fetched.purchaseDate == created)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func createRejectsBlankName(_ name: String) throws {
        let container = try makeContainer()
        #expect(throws: LicenseValidationError.emptyProductName) {
            let license = try License(productName: name, createdAt: t)
            container.mainContext.insert(license)
        }
        try container.mainContext.save()
        #expect(try count(in: container) == 0)
    }

    @Test func createKeepsNameUntrimmed() throws {
        let container = try makeContainer()
        let license = try License(productName: " Example App ", createdAt: t)
        container.mainContext.insert(license)
        try container.mainContext.save()

        let fetched = try #require(try fetch(license.id, in: container).first)
        #expect(fetched.productName == " Example App ")
    }

    @Test func updateChangesFieldsAndBumpsUpdatedAt() throws {
        let container = try makeContainer()
        let license = try insertExample(in: container)
        let id = license.id

        try license.update(
            productName: license.productName,
            vendor: license.vendor,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: "2.0",
            notes: license.notes,
            now: tPlus1
        )
        try container.mainContext.save()

        let fetched = try #require(try fetch(id, in: container).first)
        #expect(fetched.id == id)
        #expect(fetched.version == "2.0")
        #expect(fetched.updatedAt == tPlus1)
        #expect(fetched.createdAt == t)
        #expect(fetched.productName == "Example App")
    }

    @Test func updateRejectsBlankNameAndKeepsState() throws {
        let container = try makeContainer()
        let license = try insertExample(in: container)
        let before = Snapshot(license)

        #expect(throws: LicenseValidationError.emptyProductName) {
            try license.update(
                productName: "  ",
                vendor: "Other Vendor",
                registeredEmail: "user@example.com",
                purchaseDate: tPlus1,
                version: "9.9",
                notes: "Changed",
                now: tPlus1
            )
        }

        #expect(Snapshot(license) == before)
        try container.mainContext.save()
        let fetched = try #require(try fetch(before.id, in: container).first)
        #expect(fetched == before)
    }

    @Test func updateCanClearOptionalFields() throws {
        let container = try makeContainer()
        let license = try License(
            productName: "Example App",
            vendor: "Acme Corp",
            registeredEmail: "user@example.com",
            purchaseDate: t,
            version: "1.0",
            notes: "Sample note",
            createdAt: t
        )
        container.mainContext.insert(license)
        try container.mainContext.save()

        try license.update(
            productName: "Example App",
            vendor: "",
            registeredEmail: "",
            purchaseDate: nil,
            version: "",
            notes: "",
            now: tPlus1
        )
        try container.mainContext.save()

        let fetched = try #require(try fetch(license.id, in: container).first)
        #expect(fetched.vendor == "")
        #expect(fetched.registeredEmail == "")
        #expect(fetched.purchaseDate == nil)
        #expect(fetched.version == "")
        #expect(fetched.notes == "")
        #expect(fetched.updatedAt == tPlus1)
    }

    @Test func deleteRemovesEntity() throws {
        let container = try makeContainer()
        let other = try License(productName: "Other App", createdAt: t)
        container.mainContext.insert(other)
        let license = try insertExample(in: container)
        let id = license.id
        #expect(try count(in: container) == 2)

        container.mainContext.delete(license)
        try container.mainContext.save()

        #expect(try fetch(id, in: container).isEmpty)
        #expect(try count(in: container) == 1)
    }

    @Test func duplicateIdKeepsOneEntity() throws {
        let container = try makeContainer()
        let id = UUID()
        container.mainContext.insert(try License(id: id, productName: "Example App", createdAt: t))
        try container.mainContext.save()

        let duplicate = try License(id: id, productName: "Other App", vendor: "Acme Corp", createdAt: tPlus1)
        container.mainContext.insert(duplicate)
        #expect(throws: Never.self) { try container.mainContext.save() }

        #expect(try fetch(id, in: container).count == 1)
        #expect(try count(in: container) == 1)
    }
}
