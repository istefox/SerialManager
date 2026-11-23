import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Tests for `SwiftDataLicenseRepository` (SPEC 0004, R1 to R12; plan 0004, T1).
///
/// In-memory SwiftData container and `ScriptedSerialStore`: no test touches the real Keychain (R15).
/// Data is seeded through a repository with the default save hook; a persist failure is forced with a
/// second repository on the same container whose `beforeSave` throws. Persistence is checked through
/// a new `ModelContext`. Sample values are fake.
@MainActor
struct SwiftDataLicenseRepositoryTests {
    private struct PersistFailure: Error, Equatable {}

    private let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var tPlus1: Date { t.addingTimeInterval(60) }
    private let u = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let s = "ACME-0000-TEST-0000"
    private let s2 = "ACME-0000-TEST-0002"

    /// The stored fields, compared as a value.
    private struct Snapshot: Equatable {
        let id: UUID
        let productName: String
        let vendor: String
        let registeredName: String
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
            registeredName = license.registeredName
            registeredEmail = license.registeredEmail
            purchaseDate = license.purchaseDate
            version = license.version
            notes = license.notes
            createdAt = license.createdAt
            updatedAt = license.updatedAt
        }

        init(_ summary: LicenseSummary) {
            id = summary.id
            productName = summary.productName
            vendor = summary.vendor
            registeredName = summary.registeredName
            registeredEmail = summary.registeredEmail
            purchaseDate = summary.purchaseDate
            version = summary.version
            notes = summary.notes
            createdAt = summary.createdAt
            updatedAt = summary.updatedAt
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
        at date: Date? = nil,
        failingSave: Bool = false
    ) -> SwiftDataLicenseRepository {
        let fixedID = id
        let fixedDate = date ?? t
        return SwiftDataLicenseRepository(
            modelContainer: container,
            serials: serials,
            makeID: { fixedID ?? UUID() },
            now: { fixedDate },
            beforeSave: { if failingSave { throw PersistFailure() } }
        )
    }

    /// Reads every entry through a new context and copies the values while it is alive.
    private func stored(in container: ModelContainer) throws -> [Snapshot] {
        try ModelContext(container).fetch(FetchDescriptor<License>()).map(Snapshot.init)
    }

    private func draft(_ name: String = "Example App", serial: String) -> LicenseDraft {
        LicenseDraft(productName: name, vendor: "Acme Corp", serial: serial)
    }

    private func fullDraft(serial: String) -> LicenseDraft {
        LicenseDraft(
            productName: "Renamed App",
            vendor: "Example Vendor",
            registeredName: "Jane Appleseed",
            registeredEmail: "user@example.com",
            purchaseDate: Date(timeIntervalSinceReferenceDate: 700_000_000),
            version: "2.0",
            notes: "Fake notes",
            serial: serial
        )
    }

    /// Creates entry `u` "Example App" at `t` with `serial`, then clears the store's log.
    @discardableResult
    private func seed(
        _ container: ModelContainer,
        _ serials: ScriptedSerialStore,
        serial: String
    ) async throws -> Snapshot {
        let summary = try await makeRepository(container, serials, id: u).create(draft(serial: serial))
        await serials.clearLog()
        return Snapshot(summary)
    }

    /// Polls `condition`, yielding in between, and fails the test if it never holds.
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition never became true")
        throw CancellationError()
    }

    // MARK: Create

    @Test func createStoresEntryAndSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let summary = try await makeRepository(container, serials).create(draft(serial: s))

        let entries = try stored(in: container)
        #expect(entries.count == 1)
        #expect(entries.first?.productName == "Example App")
        #expect(entries.first == Snapshot(summary))
        #expect(summary.createdAt == t)
        #expect(summary.updatedAt == t)
        #expect(await serials.items == [summary.id: s])
    }

    @Test func createWithEmptySerialWritesNoItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let repository = makeRepository(container, serials)
        let summary = try await repository.create(draft(serial: ""))

        #expect(try stored(in: container).count == 1)
        #expect(await serials.items.isEmpty)
        #expect(await serials.calls(.save).isEmpty)
        #expect(try await repository.serial(for: summary.id) == nil)
    }

    @Test func createSerialFailureLeavesNothing() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        await serials.fail(.save, with: SerialStoreError.accessDenied)

        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeRepository(container, serials).create(draft(serial: s))
        }
        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items.isEmpty)
    }

    @Test func createPersistFailureDeletesSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let repository = makeRepository(container, serials, id: u, failingSave: true)

        await #expect(throws: PersistFailure()) { try await repository.create(draft(serial: s)) }
        #expect(try stored(in: container).isEmpty)
        #expect(try await repository.fetchAll().isEmpty)
        #expect(await serials.items.isEmpty)
        #expect(await serials.log.last == .init(operation: .delete, id: u))
    }

    @Test func createDuplicateIDChangesNothing() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)

        let colliding = makeRepository(container, serials, id: u, at: tPlus1)
        await #expect(throws: LicenseRepositoryError.duplicateID(u)) {
            try await colliding.create(draft("Other App", serial: s2))
        }
        #expect(try stored(in: container) == [original])
        #expect(original.productName == "Example App")
        #expect(original.createdAt == t)
        #expect(await serials.items == [u: s])
        #expect(await serials.log.isEmpty)
    }

    @Test func createAndUpdateRejectBlankName() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        let repository = makeRepository(container, serials, at: tPlus1)

        await #expect(throws: LicenseValidationError.emptyProductName) {
            try await repository.create(draft("   ", serial: s2))
        }
        await #expect(throws: LicenseValidationError.emptyProductName) {
            try await repository.update(id: u, with: draft(" \n", serial: s2))
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s])
        #expect(await serials.log.isEmpty)
    }

    // MARK: Update

    @Test func updateReplacesFieldsAndSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)

        let new = fullDraft(serial: s2)
        let summary = try await makeRepository(container, serials, at: tPlus1).update(id: u, with: new)

        let entries = try stored(in: container)
        #expect(entries == [Snapshot(summary)])
        #expect(summary.id == u)
        #expect(summary.createdAt == original.createdAt)
        #expect(summary.updatedAt == tPlus1)
        #expect(summary.productName == new.productName)
        #expect(summary.vendor == new.vendor)
        #expect(summary.registeredName == new.registeredName)
        #expect(summary.registeredEmail == new.registeredEmail)
        #expect(summary.purchaseDate == new.purchaseDate)
        #expect(summary.version == new.version)
        #expect(summary.notes == new.notes)
        #expect(await serials.items == [u: s2])
    }

    @Test func updateWithEmptySerialDeletesItem() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: s)

        let summary = try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft(serial: ""))

        #expect(await serials.items.isEmpty)
        #expect(try stored(in: container) == [Snapshot(summary)])
        #expect(summary.updatedAt == tPlus1)
        #expect(summary.createdAt == t)
    }

    @Test func updateWithSameSerialOnlyReadsIt() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)

        // Persist failure: nothing was written, so nothing is compensated.
        await #expect(throws: PersistFailure()) {
            try await makeRepository(container, serials, at: tPlus1, failingSave: true)
                .update(id: u, with: draft("Renamed App", serial: s))
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.log == [.init(operation: .read, id: u)])

        // Success: the fields change, the item is left alone.
        await serials.clearLog()
        let summary = try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft("Renamed App", serial: s))
        #expect(summary.productName == "Renamed App")
        #expect(await serials.items == [u: s])
        #expect(await serials.log == [.init(operation: .read, id: u)])
    }

    @Test func updateUnknownIDThrowsNotFound() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let id = UUID()

        await #expect(throws: LicenseRepositoryError.notFound(id)) {
            try await makeRepository(container, serials).update(id: id, with: draft(serial: s))
        }
        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
        #expect(try stored(in: container).isEmpty)
    }

    @Test func updateSerialFailureKeepsEntry() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.save, with: SerialStoreError.accessDenied)

        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(try stored(in: container) == [original])
        #expect(original.updatedAt == t)
        #expect(await serials.items == [u: s])
    }

    @Test func updateDeleteSerialFailureKeepsEntry() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.delete, with: SerialStoreError.unexpected(status: -25308))

        await #expect(throws: SerialStoreError.unexpected(status: -25308)) {
            try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft("Renamed App", serial: ""))
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s])
    }

    @Test func updatePersistFailureRestoresSerial() async throws {
        // Previous serial S: the new one is replaced by S again.
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        let failing = makeRepository(container, serials, at: tPlus1, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failing.update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(try stored(in: container) == [original])
        #expect(try await failing.fetchAll().map(Snapshot.init) == [original])
        #expect(await serials.items == [u: s])

        // No previous serial: the item saved by the update is deleted again.
        let emptyContainer = try makeContainer()
        let emptySerials = ScriptedSerialStore()
        let withoutSerial = try await seed(emptyContainer, emptySerials, serial: "")
        let failingEmpty = makeRepository(emptyContainer, emptySerials, at: tPlus1, failingSave: true)

        await #expect(throws: PersistFailure()) {
            try await failingEmpty.update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(try stored(in: emptyContainer) == [withoutSerial])
        #expect(await emptySerials.items.isEmpty)
        #expect(await emptySerials.log.last == .init(operation: .delete, id: u))
    }

    @Test func updateReadDeniedWritesNothing() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.read, with: SerialStoreError.accessDenied)

        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.calls(.delete).isEmpty)
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s])
    }

    // MARK: Delete

    @Test func deleteRemovesBoth() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: s)

        try await makeRepository(container, serials).delete(id: u)

        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items.isEmpty)
    }

    @Test func deleteSerialFailureKeepsEntry() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.delete, with: SerialStoreError.accessDenied)

        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeRepository(container, serials).delete(id: u)
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s])
    }

    @Test func deletePersistFailureRestoresSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        let failing = makeRepository(container, serials, failingSave: true)

        await #expect(throws: PersistFailure()) { try await failing.delete(id: u) }
        #expect(try stored(in: container) == [original])
        #expect(try await failing.fetchAll().map(Snapshot.init) == [original])
        #expect(await serials.items == [u: s])
    }

    @Test func deleteUnknownIDStillDeletesSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let id = UUID()

        try await makeRepository(container, serials).delete(id: id)

        #expect(await serials.calls(.delete) == [.init(operation: .delete, id: id)])
    }

    @Test(arguments: [SerialStoreError.accessDenied, .unexpected(status: -25308)])
    func deleteReadFailureWritesNothing(error: SerialStoreError) async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.read, with: error)

        await #expect(throws: error) { try await makeRepository(container, serials).delete(id: u) }
        #expect(await serials.calls(.delete).isEmpty)
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s])
    }

    // MARK: Missing serial and reads

    @Test func fetchAllReturnsEntryWithoutSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.removeItem(for: u)
        let repository = makeRepository(container, serials)

        #expect(try await repository.fetchAll().map(Snapshot.init) == [original])
        #expect(await serials.calls(.read).isEmpty)
        #expect(try await repository.serial(for: u) == nil)
    }

    @Test func serialPassesStoreErrorsThrough() async throws {
        let serials = ScriptedSerialStore(items: [u: s])
        await serials.fail(.read, with: SerialStoreError.unexpected(status: -25293))

        await #expect(throws: SerialStoreError.unexpected(status: -25293)) {
            try await makeRepository(try makeContainer(), serials).serial(for: u)
        }
    }

    // MARK: Failed rollback (R12, D3, D9)

    @Test func failedCompensationThrowsOriginalError() async throws {
        // Create: the serial delete fails, so an orphan serial remains.
        let createContainer = try makeContainer()
        let createSerials = ScriptedSerialStore()
        await createSerials.fail(.delete, with: SerialStoreError.accessDenied)
        await #expect(throws: PersistFailure()) {
            try await makeRepository(createContainer, createSerials, id: u, failingSave: true).create(draft(serial: s))
        }
        #expect(try stored(in: createContainer).isEmpty)
        #expect(await createSerials.items == [u: s])

        // Update: restoring S fails, so the old fields stay with the new serial (stale serial).
        let updateContainer = try makeContainer()
        let updateSerials = ScriptedSerialStore()
        let original = try await seed(updateContainer, updateSerials, serial: s)
        await updateSerials.fail(.save, with: SerialStoreError.accessDenied, after: 1)
        await #expect(throws: PersistFailure()) {
            try await makeRepository(updateContainer, updateSerials, at: tPlus1, failingSave: true)
                .update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(try stored(in: updateContainer) == [original])
        #expect(await updateSerials.items == [u: s2])
        #expect(await updateSerials.calls(.save).count == 2)

        // Delete: restoring S fails, so the entry stays without its serial.
        let deleteContainer = try makeContainer()
        let deleteSerials = ScriptedSerialStore()
        let kept = try await seed(deleteContainer, deleteSerials, serial: s)
        await deleteSerials.fail(.save, with: SerialStoreError.accessDenied)
        await #expect(throws: PersistFailure()) {
            try await makeRepository(deleteContainer, deleteSerials, failingSave: true).delete(id: u)
        }
        #expect(try stored(in: deleteContainer) == [kept])
        #expect(await deleteSerials.items.isEmpty)
        #expect(await deleteSerials.calls(.save).count == 1)
    }

    @Test func undecodableReadDoesNotBlock() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: s)
        await serials.fail(.read, with: SerialStoreError.undecodableData)

        let summary = try await makeRepository(container, serials, at: tPlus1).update(id: u, with: draft("Renamed App", serial: s2))
        #expect(summary.productName == "Renamed App")
        #expect(await serials.items == [u: s2])

        try await makeRepository(container, serials).delete(id: u)
        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items.isEmpty)
    }

    @Test func undecodableUpdatePersistFailureKeepsNewSerial() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.read, with: SerialStoreError.undecodableData)

        await #expect(throws: PersistFailure()) {
            try await makeRepository(container, serials, at: tPlus1, failingSave: true)
                .update(id: u, with: draft("Renamed App", serial: s2))
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.items == [u: s2])
        #expect(await serials.log == [.init(operation: .read, id: u), .init(operation: .save, id: u)])
    }

    @Test func undecodableDeletePersistFailureLeavesItemDeleted() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        let original = try await seed(container, serials, serial: s)
        await serials.fail(.read, with: SerialStoreError.undecodableData)

        await #expect(throws: PersistFailure()) {
            try await makeRepository(container, serials, failingSave: true).delete(id: u)
        }
        #expect(try stored(in: container) == [original])
        #expect(await serials.items.isEmpty)
        #expect(await serials.calls(.save).isEmpty)
        #expect(await serials.log == [.init(operation: .read, id: u), .init(operation: .delete, id: u)])
    }

    // MARK: Serialised mutations (I3)

    @Test(.timeLimit(.minutes(1)))
    func overlappingMutationsRunInOrder() async throws {
        let container = try makeContainer()
        let serials = ScriptedSerialStore()
        try await seed(container, serials, serial: s)
        let repository = makeRepository(container, serials, at: tPlus1)
        let id = u
        let update = draft("Renamed App", serial: s2)

        await serials.closeGate(.delete)
        let deletion = Task { try await repository.delete(id: id) }
        try await waitUntil { await serials.calls(.delete).count == 1 }

        let edit = Task { try await repository.update(id: id, with: update) }
        // S9: the update must be proven suspended in the lock before the gate opens.
        try await waitUntil { await repository.pendingMutationCount == 1 }
        await serials.openGate(.delete)

        try await deletion.value
        await #expect(throws: LicenseRepositoryError.notFound(id)) { try await edit.value }
        #expect(try stored(in: container).isEmpty)
        #expect(await serials.items.isEmpty)
        // Only delete's calls: the update made none, before or after delete's last call.
        #expect(await serials.log == [.init(operation: .read, id: id), .init(operation: .delete, id: id)])
        #expect(await repository.pendingMutationCount == 0)
    }
}
