import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Main window list behaviour on the real repository (SPEC 0005, R1 to R4 and an automated proxy
/// for R6; plan 0005, section 3.2 and T1).
///
/// Each test builds an in-memory SwiftData container and an `InMemorySerialStore`: never the real
/// Keychain. After construction only the `LicenseRepository` contract is used, and assertions run
/// on a fresh `LicenseStore` after `load()`, so the order comes from `fetchAll()` plus the store's
/// own sort, never from the local re-sort done by `LicenseStore.save`. Sample values are fake.
@MainActor
struct LicenseListIntegrationTests {
    private struct Fixture {
        let name: String
        let vendor: String
        let serial: String

        var draft: LicenseDraft {
            LicenseDraft(productName: name, vendor: vendor, serial: serial)
        }
    }

    /// SPEC fixture, in the unsorted creation order zeta, Alpha, Beta.
    private let fixtures = [
        Fixture(name: "zeta Test App", vendor: "Fake Vendor One", serial: "FAKE-0000-TEST"),
        Fixture(name: "Alpha Test Tool", vendor: "Example Corp", serial: "FAKE-0001-TEST"),
        Fixture(name: "Beta Test Suite", vendor: "ACME Fake", serial: "FAKE-0002-TEST"),
    ]

    private let sortedNames = ["Alpha Test Tool", "Beta Test Suite", "zeta Test App"]

    // MARK: Helpers

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// The only place that names #4's concrete type (plan 0005, section 2, question 1).
    private func makeRepository(container: ModelContainer, serials: any SerialStore) -> any LicenseRepository {
        SwiftDataLicenseRepository(modelContainer: container, serials: serials)
    }

    /// Creates `fixtures` through the repository, in their given order.
    private func seed(_ repository: any LicenseRepository, with fixtures: [Fixture]) async throws {
        for fixture in fixtures {
            _ = try await repository.create(fixture.draft)
        }
    }

    /// A store that has never seen the seeded data, loaded from the repository.
    private func loadedStore(_ repository: any LicenseRepository) async -> LicenseStore {
        let store = LicenseStore(repository: repository)
        await store.load()
        return store
    }

    /// Repository over a new in-memory container, seeded with the SPEC fixture.
    private func seededRepository() async throws -> any LicenseRepository {
        let repository = makeRepository(container: try makeContainer(), serials: InMemorySerialStore())
        try await seed(repository, with: fixtures)
        return repository
    }

    // MARK: R1

    @Test func listIsSortedByNameWhateverTheRepositoryOrder() async throws {
        let store = await loadedStore(try await seededRepository())

        #expect(store.phase == .loaded)
        #expect(store.licenses.map(\.productName) == sortedNames)
        #expect(store.licenses.map(\.vendor) == ["Example Corp", "ACME Fake", "Fake Vendor One"])
    }

    /// Discriminates case-insensitive from binary order: binary puts "Beta" before "alpha"
    /// (uppercase sorts first). The SPEC fixture alone cannot tell the two apart.
    @Test func sortIgnoresCaseOnRealRepository() async throws {
        let repository = makeRepository(container: try makeContainer(), serials: InMemorySerialStore())
        try await seed(repository, with: [
            Fixture(name: "Beta Fake Upper", vendor: "ACME Fake", serial: "FAKE-0004-TEST"),
            Fixture(name: "alpha Fake Lower", vendor: "Example Corp", serial: "FAKE-0005-TEST"),
        ])

        let store = await loadedStore(repository)

        #expect(store.licenses.map(\.productName) == ["alpha Fake Lower", "Beta Fake Upper"])
    }

    // MARK: R2

    @Test func searchMatchesVendorIgnoringCase() async throws {
        let store = await loadedStore(try await seededRepository())
        store.searchText = "acme"

        #expect(store.visibleLicenses.map(\.productName) == ["Beta Test Suite"])
    }

    @Test func searchMatchesNameIgnoringCase() async throws {
        let store = await loadedStore(try await seededRepository())
        store.searchText = "ALPHA"

        #expect(store.visibleLicenses.map(\.productName) == ["Alpha Test Tool"])
    }

    @Test func whitespaceQueryShowsEverything() async throws {
        let store = await loadedStore(try await seededRepository())
        store.searchText = "   "

        #expect(store.visibleLicenses.map(\.productName) == sortedNames)
    }

    // MARK: R3, R4

    @Test func noSearchResultsIsNotEmptyState() async throws {
        let store = await loadedStore(try await seededRepository())
        store.searchText = "nothing here"

        #expect(store.visibleLicenses.isEmpty)
        #expect(store.licenses.count == 3)
        #expect(store.isEmpty == false)
    }

    @Test func emptyContainerIsEmptyState() async throws {
        let repository = makeRepository(container: try makeContainer(), serials: InMemorySerialStore())
        let store = await loadedStore(repository)

        #expect(store.phase == .loaded)
        #expect(store.isEmpty)
        #expect(store.visibleLicenses.isEmpty)
    }

    // MARK: R6 (automated proxy; the quit-and-relaunch check is manual, plan T4)

    @Test func listSurvivesAStoreReload() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let firstStore = LicenseStore(repository: makeRepository(container: container, serials: serials))
        await firstStore.load()
        for fixture in fixtures {
            try await firstStore.save(fixture.draft)
        }

        let reloaded = await loadedStore(makeRepository(container: container, serials: serials))

        #expect(reloaded.phase == .loaded)
        #expect(reloaded.licenses.map(\.productName) == sortedNames)
        let beta = try #require(reloaded.licenses.first { $0.productName == "Beta Test Suite" })
        #expect(await reloaded.serial(for: beta.id) == .present("FAKE-0002-TEST"))
    }
}
