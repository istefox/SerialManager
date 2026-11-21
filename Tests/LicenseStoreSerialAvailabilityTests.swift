import Foundation
import Testing
@testable import SerialManager

/// `LicenseStore.isSelectedSerialAvailable`, which enables Copy Serial and Show or Hide Serial.
/// Invariants I1 to I8 of docs/plans/0007-license-detail-plan.md, section 2.2.
@MainActor
struct LicenseStoreSerialAvailabilityTests {
    private struct Boom: Error {}

    private func makeStore(_ repository: any LicenseRepository) async -> LicenseStore {
        let store = LicenseStore(repository: repository)
        await store.load()
        return store
    }

    // I1
    @Test func falseWithoutSelectedEntry() async {
        let repository = InMemoryLicenseRepository.sample()
        let store = await makeStore(repository)
        #expect(!store.isSelectedSerialAvailable)

        store.selection = SampleData.first.id
        _ = await store.serial(for: SampleData.first.id)
        #expect(store.isSelectedSerialAvailable)

        // A failed reload empties the list but keeps the selection.
        await repository.setFailure(Boom())
        await store.load()
        #expect(store.selection == SampleData.first.id)
        #expect(store.selectedLicense == nil)
        #expect(!store.isSelectedSerialAvailable)
    }

    // I2
    @Test func trueWhenDetailFoundSerial() async {
        let store = await makeStore(InMemoryLicenseRepository.sample())
        store.selection = SampleData.first.id
        #expect(await store.serial(for: SampleData.first.id) == .present("ACME-0000-TEST-0000"))
        #expect(store.isSelectedSerialAvailable)
    }

    // I3
    @Test func falseWhenSerialMissingOrFailed() async {
        let repository = InMemoryLicenseRepository.sample()
        let store = await makeStore(repository)

        store.selection = SampleData.missingSerial.id
        #expect(await store.serial(for: SampleData.missingSerial.id) == .missing)
        #expect(!store.isSelectedSerialAvailable)

        store.selection = SampleData.first.id
        await repository.setFailure(Boom())
        guard case .failed = await store.serial(for: SampleData.first.id) else {
            Issue.record("expected a failed lookup")
            return
        }
        #expect(!store.isSelectedSerialAvailable)
    }

    // I4
    @Test func falseWhileLookupInFlight() async {
        let repository = GatedLicenseRepository(entries: SampleData.licenses)
        let store = await makeStore(repository)
        let id = SampleData.first.id
        store.selection = id

        let first = Task { await store.serial(for: id) }
        await repository.waitForCalls(1)
        #expect(!store.isSelectedSerialAvailable)
        await repository.release(call: 0, with: .success("ACME-0000-TEST-0000"))
        _ = await first.value
        #expect(store.isSelectedSerialAvailable)

        let second = Task { await store.serial(for: id) }
        await repository.waitForCalls(2)
        #expect(!store.isSelectedSerialAvailable)
        await repository.release(call: 1, with: .success("ACME-0000-TEST-0000"))
        _ = await second.value
        #expect(store.isSelectedSerialAvailable)
    }

    // I5
    @Test(arguments: [false, true])
    func lastCompletedLookupWins(laterCallFindsSerial: Bool) async {
        let repository = GatedLicenseRepository(entries: SampleData.licenses)
        let store = await makeStore(repository)
        let id = SampleData.first.id
        store.selection = id

        let earlier = Task { await store.serial(for: id) }
        await repository.waitForCalls(1)
        let later = Task { await store.serial(for: id) }
        await repository.waitForCalls(2)

        // Complete the later call first, then the earlier one: the earlier one completes last.
        let present: Result<String?, any Error> = .success("ACME-0000-TEST-0000")
        let missing: Result<String?, any Error> = .success(nil)
        await repository.release(call: 1, with: laterCallFindsSerial ? present : missing)
        _ = await later.value
        #expect(store.isSelectedSerialAvailable == laterCallFindsSerial)
        await repository.release(call: 0, with: laterCallFindsSerial ? missing : present)
        _ = await earlier.value
        #expect(store.isSelectedSerialAvailable == !laterCallFindsSerial)
    }

    // I6
    @Test func selectionChangeWaitsForNewLookup() async {
        let store = await makeStore(InMemoryLicenseRepository.sample())
        let a = SampleData.first.id
        let b = SampleData.entries[1].0.id

        store.selection = a
        _ = await store.serial(for: a)
        #expect(store.isSelectedSerialAvailable)

        store.selection = b
        #expect(!store.isSelectedSerialAvailable)
        _ = await store.serial(for: b)
        #expect(store.isSelectedSerialAvailable)

        store.selection = a
        #expect(!store.isSelectedSerialAvailable)
        _ = await store.serial(for: a)
        #expect(store.isSelectedSerialAvailable)
    }

    // I7
    @Test func saveAndDeleteFollowTheNextLookup() async throws {
        let store = await makeStore(InMemoryLicenseRepository.sample())
        let entry = SampleData.missingSerial
        store.selection = entry.id
        _ = await store.serial(for: entry.id)
        #expect(!store.isSelectedSerialAvailable)

        _ = try await store.save(LicenseDraft(entry, serial: "FICTIONAL-0000-TEST"), id: entry.id)
        _ = await store.serial(for: entry.id)
        #expect(store.isSelectedSerialAvailable)

        _ = try await store.save(LicenseDraft(entry, serial: ""), id: entry.id)
        #expect(await store.serial(for: entry.id) == .missing)
        #expect(!store.isSelectedSerialAvailable)

        store.selection = SampleData.first.id
        _ = await store.serial(for: SampleData.first.id)
        try await store.delete(id: SampleData.first.id)
        #expect(!store.isSelectedSerialAvailable)
        #expect(store.detailSerialFound[SampleData.first.id] == nil)
    }

    // I8
    @Test func editFormReadDoesNotChangeAvailability() async {
        let repository = InMemoryLicenseRepository.sample()
        let store = await makeStore(repository)
        let entry = SampleData.first
        store.selection = entry.id

        // Detail failed, form read succeeds: still unavailable.
        await repository.setFailure(Boom())
        _ = await store.serial(for: entry.id)
        await repository.setFailure(nil)
        let succeeding = LicenseFormModel(license: entry)
        await succeeding.loadSerial(from: store)
        #expect(succeeding.draft.serial == "ACME-0000-TEST-0000")
        #expect(!store.isSelectedSerialAvailable)

        // Detail present, form read fails: still available.
        _ = await store.serial(for: entry.id)
        #expect(store.isSelectedSerialAvailable)
        await repository.setFailure(Boom())
        let failing = LicenseFormModel(license: entry)
        await failing.loadSerial(from: store)
        #expect(failing.serialUnreadable)
        #expect(store.isSelectedSerialAvailable)
    }
}

/// A repository whose `serial(for:)` calls wait until the test releases them, one by one, in
/// any order. Other operations succeed immediately on the given entries.
private actor GatedLicenseRepository: LicenseRepository {
    private let licenses: [LicenseSummary]
    private var pending: [Int: CheckedContinuation<String?, any Error>] = [:]
    private var callCount = 0

    init(entries: [LicenseSummary]) { licenses = entries }

    func fetchAll() async throws -> [LicenseSummary] { licenses }
    func create(_ draft: LicenseDraft) async throws -> LicenseSummary { throw CancellationError() }
    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary {
        throw CancellationError()
    }
    func delete(id: UUID) async throws {}
    func importLicense(_ license: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome { throw CancellationError() }

    func serial(for id: UUID) async throws -> String? {
        let call = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    /// Returns once `count` calls to `serial(for:)` have started.
    func waitForCalls(_ count: Int) async {
        while callCount < count { await Task.yield() }
    }

    func release(call: Int, with result: Result<String?, any Error>) {
        pending.removeValue(forKey: call)?.resume(with: result)
    }
}
