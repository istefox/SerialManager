import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Tests for `LicenseRepository.importLicense` (SPEC 0010 R6 to R8, D3, D4; plan 0010, 2.3 and T1).
///
/// SwiftData on an in-memory container and `ScriptedSerialStore`: no test touches the real Keychain.
/// Dates sit on whole milliseconds and are compared at millisecond precision. Sample values are fake.
@MainActor
struct LicenseRepositoryImportTests {
    private struct PersistFailure: Error, Equatable {}

    private let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let u = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let localSerial = "FAKE-1111-1111-1111"
    private let fileSerial = "FAKE-2222-2222-2222"

    /// Every stored field, dates rounded to the millisecond.
    private struct Snapshot: Equatable {
        let id: UUID
        let productName: String
        let vendor: String
        let registeredName: String
        let registeredEmail: String
        let purchaseDate: Int64?
        let version: String
        let notes: String
        let createdAt: Int64
        let updatedAt: Int64

        init(_ s: LicenseSummary) {
            id = s.id
            productName = s.productName
            vendor = s.vendor
            registeredName = s.registeredName
            registeredEmail = s.registeredEmail
            purchaseDate = s.purchaseDate.map(Snapshot.ms)
            version = s.version
            notes = s.notes
            createdAt = Snapshot.ms(s.createdAt)
            updatedAt = Snapshot.ms(s.updatedAt)
        }

        init(_ l: License) {
            id = l.id
            productName = l.productName
            vendor = l.vendor
            registeredName = l.registeredName
            registeredEmail = l.registeredEmail
            purchaseDate = l.purchaseDate.map(Snapshot.ms)
            version = l.version
            notes = l.notes
            createdAt = Snapshot.ms(l.createdAt)
            updatedAt = Snapshot.ms(l.updatedAt)
        }

        static func ms(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
    }

    // MARK: Helpers

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeRepository(
        _ container: ModelContainer,
        _ serials: ScriptedSerialStore,
        id: UUID? = nil,
        failingSave: Bool = false
    ) -> SwiftDataLicenseRepository {
        let fixedID = id
        let fixedDate = t
        return SwiftDataLicenseRepository(
            modelContainer: container,
            serials: serials,
            makeID: { fixedID ?? UUID() },
            now: { fixedDate },
            beforeSave: { if failingSave { throw PersistFailure() } }
        )
    }

    /// Reads every entry through a new context, so the check hits the store.
    private func stored(in container: ModelContainer) throws -> [Snapshot] {
        try ModelContext(container).fetch(FetchDescriptor<License>()).map(Snapshot.init)
    }

    /// A backup record for `id`, with every field set and dates on whole milliseconds.
    private func record(_ id: UUID, name: String = "Imported App", purchase: Bool = true) -> LicenseSummary {
        LicenseSummary(
            id: id,
            productName: name,
            vendor: "Example Vendor",
            registeredName: "Jane Appleseed",
            registeredEmail: "user@example.com",
            purchaseDate: purchase ? Date(timeIntervalSinceReferenceDate: 600_000_000.125) : nil,
            version: "4.2",
            notes: "Fake imported notes",
            createdAt: Date(timeIntervalSinceReferenceDate: 650_000_000.250),
            updatedAt: Date(timeIntervalSinceReferenceDate: 650_500_000.750)
        )
    }

    /// Creates license `u` "Example App" at `t` with `serial` through the app's own path, then clears
    /// the serial store log.
    @discardableResult
    private func seed(
        _ container: ModelContainer,
        _ serials: ScriptedSerialStore,
        serial: String
    ) async throws -> Snapshot {
        let draft = LicenseDraft(productName: "Example App", vendor: "Acme Corp", notes: "Local notes", serial: serial)
        let summary = try await makeRepository(container, serials, id: u).create(draft)
        await serials.clearLog()
        return Snapshot(summary)
    }

    // MARK: Create

    @Test func createWithSerialStoresEveryFieldAndBothDates() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let repository = makeRepository(container, serials)

        let outcome = try await repository.importLicense(record(u), serial: fileSerial, policy: .skip)

        #expect(outcome == .created)
        #expect(try stored(in: container) == [Snapshot(record(u))])
        #expect(await serials.items == [u: fileSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test(arguments: [nil, ""] as [String?])
    func createWithoutSerialWritesNoItem(_ serial: String?) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()

        let outcome = try await makeRepository(container, serials)
            .importLicense(record(u, purchase: false), serial: serial, policy: .replace)

        #expect(outcome == .created)
        #expect(try stored(in: container) == [Snapshot(record(u, purchase: false))])
        #expect(await serials.items.isEmpty)
        #expect(await serials.log.isEmpty)
    }

    // MARK: Skip

    @Test(arguments: [nil, "", "FAKE-2222-2222-2222"] as [String?])
    func skipLeavesTheExistingLicenseIdentical(_ serial: String?) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        let repository = makeRepository(container, serials)

        let outcome = try await repository.importLicense(record(u), serial: serial, policy: .skip)

        #expect(outcome == .skipped)
        #expect(try stored(in: container) == [before])
        #expect(try await repository.fetchAll().map(Snapshot.init) == [before])
        #expect(await serials.items == [u: localSerial])
        #expect(await serials.log.isEmpty)
    }

    // MARK: Replace

    @Test func replaceWithSerialReplacesFieldsDatesAndItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: localSerial)

        let outcome = try await makeRepository(container, serials)
            .importLicense(record(u), serial: fileSerial, policy: .replace)

        #expect(outcome == .replaced)
        #expect(try stored(in: container) == [Snapshot(record(u))])
        #expect(await serials.items == [u: fileSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test(arguments: [nil, ""] as [String?])
    func replaceWithoutSerialKeepsTheLocalItem(_ serial: String?) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: localSerial)

        let outcome = try await makeRepository(container, serials)
            .importLicense(record(u), serial: serial, policy: .replace)

        #expect(outcome == .replaced)
        #expect(try stored(in: container) == [Snapshot(record(u))])
        #expect(await serials.items == [u: localSerial])
        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func replaceWithTheSameSerialWritesNoItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: localSerial)

        _ = try await makeRepository(container, serials).importLicense(record(u), serial: localSerial, policy: .replace)

        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
        #expect(await serials.items == [u: localSerial])
    }

    @Test func blankNameIsRejectedBeforeAnyWrite() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        let repository = makeRepository(container, serials)

        for policy in [ConflictPolicy.replace, .skip] {
            await #expect(throws: LicenseValidationError.emptyProductName) {
                try await repository.importLicense(record(u, name: "  "), serial: fileSerial, policy: policy)
            }
        }
        let other = UUID()
        await #expect(throws: LicenseValidationError.emptyProductName) {
            try await repository.importLicense(record(other, name: "\n"), serial: fileSerial, policy: .skip)
        }

        #expect(try stored(in: container) == [before])
        #expect(await serials.log.isEmpty)
    }

    // MARK: D4, persist failure

    @Test func createPersistFailureLeavesNoLicenseAndNoItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let failing = makeRepository(container, serials, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failing.importLicense(record(u), serial: fileSerial, policy: .skip)
        }

        #expect(try stored(in: container).isEmpty)
        #expect(try await failing.fetchAll().isEmpty)
        #expect(await serials.items.isEmpty)
        // The only removal is the compensation of the item this call created.
        #expect(await serials.log.map(\.operation) == [.read, .save, .delete])
    }

    @Test func replacePersistFailureKeepsFieldsDatesAndRestoresTheItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        let failing = makeRepository(container, serials, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failing.importLicense(record(u), serial: fileSerial, policy: .replace)
        }

        #expect(try stored(in: container) == [before])
        #expect(try await failing.fetchAll().map(Snapshot.init) == [before])
        #expect(await serials.items == [u: localSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func createOverAnOrphanRestoresTheOrphanOnFailure() async throws {
        let container = try makeContainer()
        let orphan = "FAKE-0RPH-0000-0000"
        let serials = ScriptedSerialStore(items: [u: orphan])
        let failing = makeRepository(container, serials, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failing.importLicense(record(u), serial: fileSerial, policy: .skip)
        }

        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items == [u: orphan])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func replaceOverALicenseWithNoItemRemovesOnlyItsOwnItemOnFailure() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: "")
        let failing = makeRepository(container, serials, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failing.importLicense(record(u), serial: fileSerial, policy: .replace)
        }

        #expect(try stored(in: container) == [before])
        #expect(try await failing.fetchAll().map(Snapshot.init) == [before])
        #expect(await serials.items.isEmpty)
        #expect(await serials.log.map(\.operation) == [.read, .save, .delete])
    }

    @Test func createOverAnOrphanWithoutFileSerialKeepsTheOrphan() async throws {
        let container = try makeContainer()
        let orphan = "FAKE-0RPH-0000-0000"
        let serials = ScriptedSerialStore(items: [u: orphan])

        let outcome = try await makeRepository(container, serials).importLicense(record(u), serial: nil, policy: .skip)

        #expect(outcome == .created)
        #expect(await serials.items == [u: orphan])
        #expect(await serials.log.isEmpty)
    }

    // MARK: Serial store failures

    @Test(arguments: [ConflictPolicy.skip, .replace])
    func serialSaveFailureWritesNothingAndRethrows(_ policy: ConflictPolicy) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        await serials.fail(.save, with: SerialStoreError.accessDenied)
        let repository = makeRepository(container, serials)

        // New license: the policy does not matter.
        await #expect(throws: SerialStoreError.accessDenied) {
            try await repository.importLicense(record(u), serial: fileSerial, policy: policy)
        }

        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items.isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func replaceSaveFailureKeepsTheExistingLicense() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        await serials.fail(.save, with: SerialStoreError.accessDenied)

        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeRepository(container, serials).importLicense(record(u), serial: fileSerial, policy: .replace)
        }

        #expect(try stored(in: container) == [before])
        #expect(await serials.items == [u: localSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func undecodablePreviousSerialDoesNotBlockTheWrite() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: localSerial)
        await serials.fail(.read, with: SerialStoreError.undecodableData)

        let outcome = try await makeRepository(container, serials)
            .importLicense(record(u), serial: fileSerial, policy: .replace)

        #expect(outcome == .replaced)
        #expect(try stored(in: container) == [Snapshot(record(u))])
        #expect(await serials.items == [u: fileSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func undecodablePreviousSerialIsNotRemovedOnFailure() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        await serials.fail(.read, with: SerialStoreError.undecodableData)

        await #expect(throws: PersistFailure()) {
            try await makeRepository(container, serials, failingSave: true)
                .importLicense(record(u), serial: fileSerial, policy: .replace)
        }

        #expect(try stored(in: container) == [before])
        // Previous value unknown: the new value stays (D9 of plan 0004), nothing is removed.
        #expect(await serials.items == [u: fileSerial])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test(arguments: [SerialStoreError.accessDenied, .unexpected(status: -25308)])
    func previousReadFailureStopsBeforeAnyWrite(_ error: SerialStoreError) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let before = try await seed(container, serials, serial: localSerial)
        await serials.fail(.read, with: error)

        await #expect(throws: error) {
            try await makeRepository(container, serials).importLicense(record(u), serial: fileSerial, policy: .replace)
        }

        #expect(try stored(in: container) == [before])
        #expect(await serials.items == [u: localSerial])
        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
    }

    // MARK: In-memory repository

    @Test func inMemoryImportFollowsTheSameRules() async throws {
        let existing = record(u, name: "Existing App")
        let repository = InMemoryLicenseRepository(entries: [(existing, localSerial)])
        let other = UUID()

        #expect(try await repository.importLicense(record(u), serial: fileSerial, policy: .skip) == .skipped)
        #expect(try await repository.fetchAll() == [existing])
        #expect(try await repository.serial(for: u) == localSerial)

        #expect(try await repository.importLicense(record(u), serial: "", policy: .replace) == .replaced)
        #expect(try await repository.fetchAll() == [record(u)])
        #expect(try await repository.serial(for: u) == localSerial)

        #expect(try await repository.importLicense(record(u), serial: fileSerial, policy: .replace) == .replaced)
        #expect(try await repository.serial(for: u) == fileSerial)

        #expect(try await repository.importLicense(record(other), serial: nil, policy: .skip) == .created)
        #expect(try await repository.serial(for: other) == nil)
        #expect(try await repository.fetchAll().count == 2)
    }

    @Test func inMemoryImportHonoursFailure() async {
        let repository = InMemoryLicenseRepository(failure: PersistFailure())
        await #expect(throws: PersistFailure()) {
            try await repository.importLicense(record(u), serial: nil, policy: .skip)
        }
    }
}
