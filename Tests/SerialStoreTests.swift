import Foundation
import Testing
@testable import SerialManager

/// Behaviour of the in-memory `SerialStore` (SPEC 0003, A1 to A5 and A7).
struct SerialStoreTests {
    private struct Boom: Error, Equatable {}

    @Test func saveTwiceReplacesValueWithoutDuplicates() async throws {
        let store = InMemorySerialStore()
        let id = UUID()
        try await store.save("TEST-AAAA-1111", for: id)
        try await store.save("TEST-BBBB-2222", for: id)
        #expect(try await store.serial(for: id) == "TEST-BBBB-2222")
        #expect(await store.itemCount == 1)
    }

    @Test func readOfUnknownIDReturnsNil() async throws {
        let store = InMemorySerialStore()
        #expect(try await store.serial(for: UUID()) == nil)
    }

    @Test func deleteOfUnknownIDSucceeds() async throws {
        let store = InMemorySerialStore()
        try await store.deleteSerial(for: UUID())
        #expect(await store.itemCount == 0)
    }

    @Test func deleteRemovesStoredSerial() async throws {
        let store = InMemorySerialStore()
        let id = UUID()
        try await store.save("TEST-CCCC-3333", for: id)
        try await store.deleteSerial(for: id)
        #expect(try await store.serial(for: id) == nil)
        #expect(await store.itemCount == 0)
    }

    @Test func deleteLeavesOtherSerialsUntouched() async throws {
        let kept = UUID()
        let removed = UUID()
        let store = InMemorySerialStore(serials: [kept: "TEST-KEEP-0001", removed: "TEST-DROP-0002"])
        try await store.deleteSerial(for: removed)
        #expect(try await store.serial(for: kept) == "TEST-KEEP-0001")
        #expect(await store.itemCount == 1)
    }

    @Test(arguments: ["  TÉST-ÄÖÜ-✓  ", "", "\tTEST-TAB\n", "\u{FEFF}TEST-BOM"])
    func valueRoundTripsUnchanged(_ value: String) async throws {
        let store = InMemorySerialStore()
        let id = UUID()
        try await store.save(value, for: id)
        #expect(try await store.serial(for: id) == value)
    }

    @Test func configuredFailureIsThrownByEveryOperation() async throws {
        let id = UUID()
        let store = InMemorySerialStore(serials: [id: "TEST-DDDD-4444"], failure: Boom())
        await #expect(throws: Boom.self) { try await store.save("TEST-EEEE-5555", for: id) }
        await #expect(throws: Boom.self) { try await store.serial(for: id) }
        await #expect(throws: Boom.self) { try await store.deleteSerial(for: id) }
    }

    @Test func clearingFailureRestoresBehaviour() async throws {
        let id = UUID()
        let store = InMemorySerialStore(serials: [id: "TEST-DDDD-4444"])
        await store.setFailure(SerialStoreError.accessDenied)
        await #expect(throws: SerialStoreError.accessDenied) { try await store.serial(for: id) }
        await store.setFailure(nil)
        #expect(try await store.serial(for: id) == "TEST-DDDD-4444")
    }
}
