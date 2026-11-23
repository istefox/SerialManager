import Foundation
import os
import SwiftData
import Testing
@testable import SerialManager

/// Integration tests for the license form on persistent data (SPEC `docs/specs/license-form.md`,
/// R1 to R9; plan `docs/plans/license-form-plan.md`, section 2.1, T2).
///
/// Each test drives `LicenseFormModel` against a `LicenseStore` built on the real
/// `SwiftDataLicenseRepository`, with an in-memory SwiftData container and `InMemorySerialStore`:
/// no test touches the real Keychain or the owner's library (R9). The stored state is always read
/// through a new repository instance on the same container and serial store, after any injected
/// failure has been cleared. Sample values are fake.
@MainActor
struct LicenseFormIntegrationTests {
    /// Injected serial store failure. Any error other than the "unreadable item" case stops
    /// `update` and `delete` before any write (plan F4).
    private struct InjectedFailure: Error {}

    /// Controllable clock, so an edit gets a later `updatedAt` than the save before it (plan F6).
    private final class TestClock: Sendable {
        private let state: OSAllocatedUnfairLock<Date>

        init(_ start: Date) {
            state = OSAllocatedUnfairLock(initialState: start)
        }

        var date: Date { state.withLock { $0 } }

        func advance(by seconds: TimeInterval) {
            state.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    /// What a new repository instance returns: every record, sorted by id, and each one's serial.
    private struct StoredState: Equatable {
        let licenses: [LicenseSummary]
        let serials: [UUID: String?]
    }

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let serial = "ACME-0000-TEST-0000"
    private let newSerial = "ACME-1111-TEST-1111"

    // MARK: Helpers

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A loaded `LicenseStore` on the real repository.
    private func makeStore(
        container: ModelContainer,
        serials: InMemorySerialStore,
        clock: TestClock
    ) async -> LicenseStore {
        let repository = SwiftDataLicenseRepository(
            modelContainer: container,
            serials: serials,
            now: { clock.date }
        )
        let store = LicenseStore(repository: repository)
        await store.load()
        return store
    }

    /// The stored state, read through a NEW repository instance. Call it only with no failure set.
    private func storedState(container: ModelContainer, serials: InMemorySerialStore) async throws -> StoredState {
        let reader = SwiftDataLicenseRepository(modelContainer: container, serials: serials)
        let licenses = try await reader.fetchAll().sorted { $0.id.uuidString < $1.id.uuidString }
        var stored: [UUID: String?] = [:]
        for license in licenses {
            stored[license.id] = try await reader.serial(for: license.id)
        }
        return StoredState(licenses: licenses, serials: stored)
    }

    /// Saves "Acme Editor" with `serial` through a new form and returns it as the store lists it.
    private func seed(_ store: LicenseStore) async throws -> LicenseSummary {
        let model = LicenseFormModel()
        model.draft = LicenseDraft(productName: "Acme Editor", vendor: "Acme", serial: serial)
        #expect(await model.save(to: store))
        return try #require(store.licenses.first { $0.productName == "Acme Editor" })
    }

    // MARK: R1

    @Test func loadsFromRealRepository() async throws {
        let container = try makeContainer()
        let store = await makeStore(container: container, serials: InMemorySerialStore(), clock: TestClock(start))

        // Cmd+N is enabled when the store is loaded (AppCommands).
        #expect(store.phase == .loaded)
        #expect(store.licenses.isEmpty)
    }

    // MARK: R2

    @Test func blankNameStoresNothing() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let model = LicenseFormModel()
        model.draft = LicenseDraft(productName: "   ", serial: serial)

        #expect(await model.save(to: store) == false)
        #expect(model.showsNameError)
        #expect(store.licenses.isEmpty)
        #expect(try await storedState(container: container, serials: serials).licenses.isEmpty)
        #expect(await serials.itemCount == 0)
    }

    // MARK: R3

    @Test func newLicenseStoresTrimmedRecordAndSerial() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let model = LicenseFormModel()
        model.draft = LicenseDraft(
            productName: " Acme Editor ", vendor: "Acme", registeredName: "  Jane Appleseed  ", serial: serial)

        #expect(await model.save(to: store))

        let state = try await storedState(container: container, serials: serials)
        let stored = try #require(state.licenses.first)
        #expect(state.licenses.count == 1)
        #expect(stored.productName == "Acme Editor")
        #expect(stored.vendor == "Acme")
        #expect(stored.registeredName == "Jane Appleseed")
        #expect(state.serials[stored.id] == .some(serial))
    }

    /// The registered name is optional: a license saved without it stores `""`, and an edit can
    /// set it and clear it again (ticket #17).
    @Test func registeredNameIsOptionalAndCanBeSetThenCleared() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let clock = TestClock(start)
        let store = await makeStore(container: container, serials: serials, clock: clock)
        let new = LicenseFormModel()
        new.draft = LicenseDraft(productName: "Acme Editor", serial: serial)

        #expect(await new.save(to: store))
        var stored = try #require(try await storedState(container: container, serials: serials).licenses.first)
        #expect(stored.registeredName == "")

        clock.advance(by: 60)
        let setting = LicenseFormModel(
            license: stored, draft: LicenseDraft(stored, serial: serial))
        setting.draft.registeredName = "Jane Appleseed"
        #expect(await setting.save(to: store))
        stored = try #require(try await storedState(container: container, serials: serials).licenses.first)
        #expect(stored.registeredName == "Jane Appleseed")

        clock.advance(by: 60)
        let clearing = LicenseFormModel(
            license: stored, draft: LicenseDraft(stored, serial: serial))
        clearing.draft.registeredName = "   "
        #expect(await clearing.save(to: store))
        stored = try #require(try await storedState(container: container, serials: serials).licenses.first)
        #expect(stored.registeredName == "")
    }

    // MARK: R4

    @Test func editUpdatesRecordAndSerial() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let clock = TestClock(start)
        let store = await makeStore(container: container, serials: serials, clock: clock)
        let license = try await seed(store)
        let before = try #require(try await storedState(container: container, serials: serials).licenses.first)

        clock.advance(by: 60)
        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        model.draft.version = "4.0"
        model.draft.serial = newSerial
        #expect(await model.save(to: store))

        let state = try await storedState(container: container, serials: serials)
        let stored = try #require(state.licenses.first)
        #expect(state.licenses.count == 1)
        #expect(stored.id == license.id)
        #expect(stored.version == "4.0")
        #expect(stored.updatedAt > before.updatedAt)
        #expect(state.serials[license.id] == .some(newSerial))
    }

    @Test func clearingSerialRemovesItem() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let license = try await seed(store)

        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        #expect(model.draft.serial == serial)
        model.draft.serial = ""
        #expect(await model.save(to: store))

        #expect(try await serials.serial(for: license.id) == nil)
        #expect(await serials.itemCount == 0)
        #expect(try await storedState(container: container, serials: serials).licenses.map(\.id) == [license.id])
    }

    @Test func unreadableSerialIsNotErasedOnRealRepository() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let license = try await seed(store)

        await serials.setFailure(InjectedFailure())
        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        await serials.setFailure(nil)

        #expect(model.serialUnreadable)
        #expect(await model.save(to: store) == false)
        #expect(model.errorMessage != nil)
        let state = try await storedState(container: container, serials: serials)
        #expect(state.serials[license.id] == .some(serial))
    }

    // MARK: R5

    @Test func deleteRemovesRecordAndSerial() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let license = try await seed(store)

        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        #expect(await model.delete(from: store))

        #expect(!store.licenses.contains { $0.id == license.id })
        #expect(try await storedState(container: container, serials: serials).licenses.isEmpty)
        // Checked directly: the stored-state helper only reads ids that `fetchAll()` returns.
        #expect(try await serials.serial(for: license.id) == nil)
        #expect(await serials.itemCount == 0)
    }

    // MARK: R6

    @Test func failedSaveKeepsDraftAndStoresNothing() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let model = LicenseFormModel()
        // With a serial: an empty one never calls the serial store, so nothing would fail.
        model.draft = LicenseDraft(productName: "Acme Editor", vendor: "Acme", serial: serial)
        let typed = model.draft

        await serials.setFailure(InjectedFailure())
        #expect(await model.save(to: store) == false)
        #expect(model.errorMessage != nil)
        #expect(model.draft == typed)
        #expect(store.licenses.isEmpty)
        await serials.setFailure(nil)

        #expect(try await storedState(container: container, serials: serials).licenses.isEmpty)
        #expect(await serials.itemCount == 0)
    }

    @Test func failedEditKeepsStoredRecord() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let clock = TestClock(start)
        let store = await makeStore(container: container, serials: serials, clock: clock)
        let license = try await seed(store)
        let before = try await storedState(container: container, serials: serials)

        clock.advance(by: 60)
        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        await serials.setFailure(InjectedFailure())
        model.draft.version = "4.0"
        model.draft.serial = newSerial
        #expect(await model.save(to: store) == false)
        #expect(model.errorMessage != nil)
        #expect(store.licenses == [license])
        await serials.setFailure(nil)

        #expect(try await storedState(container: container, serials: serials) == before)
    }

    // MARK: R7

    @Test func failedDeleteKeepsRecordAndSerial() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        let license = try await seed(store)
        let before = try await storedState(container: container, serials: serials)

        let model = LicenseFormModel(license: license)
        await model.loadSerial(from: store)
        await serials.setFailure(InjectedFailure())
        #expect(await model.delete(from: store) == false)
        #expect(model.errorMessage != nil)
        #expect(store.licenses.contains { $0.id == license.id })
        await serials.setFailure(nil)

        let state = try await storedState(container: container, serials: serials)
        #expect(state == before)
        #expect(state.serials[license.id] == .some(serial))
    }

    // MARK: R8

    @Test func cancelledEditWritesNothing() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let clock = TestClock(start)
        let store = await makeStore(container: container, serials: serials, clock: clock)
        let license = try await seed(store)
        let before = try await storedState(container: container, serials: serials)

        clock.advance(by: 60)
        var model: LicenseFormModel? = LicenseFormModel(license: license)
        await model?.loadSerial(from: store)
        model?.draft.notes = "Fake changed notes"
        #expect(model?.hasChanges == true)
        // Cancel, then Discard Changes: the view closes the sheet and never calls the model.
        model = nil

        #expect(try await storedState(container: container, serials: serials) == before)
        #expect(await serials.itemCount == 1)
    }

    @Test func cancelledNewWritesNothing() async throws {
        let container = try makeContainer()
        let serials = InMemorySerialStore()
        let store = await makeStore(container: container, serials: serials, clock: TestClock(start))
        _ = try await seed(store)
        let countBefore = try await storedState(container: container, serials: serials).licenses.count

        var model: LicenseFormModel? = LicenseFormModel()
        model?.draft.productName = "Acme Draft"
        #expect(model?.hasChanges == true)
        // Cancel, then Discard Changes: the view closes the sheet and never calls the model.
        model = nil

        #expect(try await storedState(container: container, serials: serials).licenses.count == countBefore)
        #expect(await serials.itemCount == 1)
    }
}
