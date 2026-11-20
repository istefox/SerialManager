import Foundation
import Security
import Testing
@testable import SerialManager

/// `KeychainSerialStore` over a dictionary-backed fake client: status mapping (A6), item
/// attributes (R6, R7) and the save/read/delete flow (R2 to R5, R8). The real Keychain is never used.
struct KeychainSerialStoreTests {
    private let service = "it.stefer.SerialManager.tests"

    private func makeStore(_ keychain: FakeKeychain) -> KeychainSerialStore {
        KeychainSerialStore(service: service, client: keychain.client)
    }

    // MARK: Status mapping (A6)

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem])
    func accessStatusesMapToAccessDenied(_ status: OSStatus) {
        #expect(SerialStoreError(status: status) == .accessDenied)
    }

    @Test func decodeStatusMapsToUndecodableData() {
        #expect(SerialStoreError(status: errSecDecode) == .undecodableData)
    }

    @Test(arguments: [errSecMissingEntitlement, OSStatus(-99999), errSecParam])
    func otherStatusesMapToUnexpectedWithStatus(_ status: OSStatus) {
        #expect(SerialStoreError(status: status) == .unexpected(status: status))
    }

    @Test func mappedConstantsHaveDocumentedValues() {
        #expect(errSecAuthFailed == -25293)
        #expect(errSecInteractionNotAllowed == -25308)
        #expect(errSecUserCanceled == -128)
        #expect(errSecNoAccessForItem == -25243)
        #expect(errSecDecode == -26275)
        #expect(errSecMissingEntitlement == -34018)
    }

    // MARK: Item attributes (R6, R7)

    @Test func everyCallCarriesTheSharedAttributes() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let id = UUID()
        try await store.save("TEST-AAAA-1111", for: id)
        _ = try await store.serial(for: id)
        try await store.deleteSerial(for: id)

        let calls = keychain.calls
        #expect(calls.map(\.operation) == [.update, .add, .copyMatching, .delete])
        for call in calls {
            #expect(call.query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(call.query[kSecAttrService as String] as? String == service)
            #expect(call.query[kSecAttrAccount as String] as? String == id.uuidString)
            #expect(call.query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(call.query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(call.query[kSecAttrAccessGroup as String] == nil)
        }
    }

    @Test func addMakesTheItemDeviceLocal() async throws {
        let keychain = FakeKeychain()
        try await makeStore(keychain).save("TEST-AAAA-1111", for: UUID())
        let add = try #require(keychain.calls.first { $0.operation == .add })
        #expect(add.query[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(add.query[kSecValueData as String] as? Data == Data("TEST-AAAA-1111".utf8))
    }

    @Test func readAsksForOneItemWithData() async throws {
        let keychain = FakeKeychain()
        _ = try await makeStore(keychain).serial(for: UUID())
        let copy = try #require(keychain.calls.first)
        #expect(copy.query[kSecReturnData as String] as? Bool == true)
        #expect(copy.query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func defaultServiceIsTheBundleIdentifier() {
        #expect(KeychainSerialStore.defaultService == Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager")
    }

    // MARK: Flow (R2 to R5)

    @Test func saveTwiceUpdatesTheSingleItem() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let id = UUID()
        try await store.save("TEST-AAAA-1111", for: id)
        try await store.save("TEST-BBBB-2222", for: id)
        #expect(try await store.serial(for: id) == "TEST-BBBB-2222")
        #expect(keychain.itemCount == 1)
        #expect(keychain.calls.map(\.operation) == [.update, .add, .update, .copyMatching])
    }

    @Test func duplicateOnAddFallsBackToUpdate() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let id = UUID()
        keychain.insert(Data("TEST-OLD-0000".utf8), service: service, account: id.uuidString)
        // A concurrent save created the item between our update and our add.
        keychain.script(.update, errSecItemNotFound)

        try await store.save("TEST-NEW-1111", for: id)

        #expect(keychain.calls.map(\.operation) == [.update, .add, .update])
        #expect(try await store.serial(for: id) == "TEST-NEW-1111")
        #expect(keychain.itemCount == 1)
    }

    @Test func concurrentDeleteAfterDuplicateSurfacesAsUnexpected() async throws {
        let keychain = FakeKeychain()
        keychain.script(.add, errSecDuplicateItem)
        await #expect(throws: SerialStoreError.unexpected(status: errSecItemNotFound)) {
            try await makeStore(keychain).save("TEST-AAAA-1111", for: UUID())
        }
    }

    @Test func readOfMissingItemReturnsNil() async throws {
        #expect(try await makeStore(FakeKeychain()).serial(for: UUID()) == nil)
    }

    @Test func deleteOfMissingItemSucceeds() async throws {
        let keychain = FakeKeychain()
        try await makeStore(keychain).deleteSerial(for: UUID())
        #expect(keychain.calls.map(\.operation) == [.delete])
    }

    @Test func deleteRemovesTheItem() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let id = UUID()
        try await store.save("TEST-CCCC-3333", for: id)
        try await store.deleteSerial(for: id)
        #expect(try await store.serial(for: id) == nil)
        #expect(keychain.itemCount == 0)
    }

    @Test(arguments: ["  TÉST-ÄÖÜ-✓  ", "", "\tTEST-TAB\n", "\u{FEFF}TEST-BOM"])
    func valueRoundTripsUnchanged(_ value: String) async throws {
        let store = makeStore(FakeKeychain())
        let id = UUID()
        try await store.save(value, for: id)
        #expect(try await store.serial(for: id) == value)
    }

    @Test func nonUTF8DataIsUndecodable() async throws {
        let keychain = FakeKeychain()
        let id = UUID()
        keychain.insert(Data([0xFF, 0xFE, 0xFD]), service: service, account: id.uuidString)
        await #expect(throws: SerialStoreError.undecodableData) {
            try await makeStore(keychain).serial(for: id)
        }
    }

    @Test func successWithoutDataIsUndecodable() async throws {
        let keychain = FakeKeychain()
        keychain.scriptCopyResult(status: errSecSuccess, result: nil)
        await #expect(throws: SerialStoreError.undecodableData) {
            try await makeStore(keychain).serial(for: UUID())
        }
    }

    @Test func saveFailureIsMapped() async throws {
        let keychain = FakeKeychain()
        keychain.script(.update, errSecInteractionNotAllowed)
        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeStore(keychain).save("TEST-AAAA-1111", for: UUID())
        }
        #expect(keychain.itemCount == 0)
    }

    @Test func addFailureIsMapped() async throws {
        let keychain = FakeKeychain()
        keychain.script(.add, errSecMissingEntitlement)
        await #expect(throws: SerialStoreError.unexpected(status: errSecMissingEntitlement)) {
            try await makeStore(keychain).save("TEST-AAAA-1111", for: UUID())
        }
    }

    @Test func readFailureIsMapped() async throws {
        let keychain = FakeKeychain()
        keychain.scriptCopyResult(status: errSecAuthFailed, result: nil)
        await #expect(throws: SerialStoreError.accessDenied) {
            try await makeStore(keychain).serial(for: UUID())
        }
    }

    @Test func deleteFailureIsMapped() async throws {
        let keychain = FakeKeychain()
        keychain.script(.delete, -99999)
        await #expect(throws: SerialStoreError.unexpected(status: -99999)) {
            try await makeStore(keychain).deleteSerial(for: UUID())
        }
    }

    // MARK: No serial in errors (R9)

    @Test(arguments: [SerialStoreError.accessDenied, .undecodableData, .unexpected(status: -99999)])
    func errorTextNeverContainsTheSerial(_ error: SerialStoreError) {
        let serial = "TEST-SECRET-9999"
        #expect(!String(describing: error).contains(serial))
        #expect(!String(reflecting: error).contains(serial))
        #expect(!error.localizedDescription.contains(serial))
    }
}

/// Dictionary-backed stand-in for the four SecItem functions. Items are keyed by service and
/// account; every call is recorded. A scripted status is returned once, instead of running the call.
private final class FakeKeychain: @unchecked Sendable {
    enum Operation: Equatable { case add, update, copyMatching, delete }

    struct Call {
        let operation: Operation
        let query: [String: Any]
    }

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var items: [Key: Data] = [:]
    private var recorded: [Call] = []
    private var scripted: [Operation: [OSStatus]] = [:]
    private var scriptedCopy: [(OSStatus, CFTypeRef?)] = []

    var calls: [Call] { lock.withLock { recorded } }
    var itemCount: Int { lock.withLock { items.count } }

    func insert(_ data: Data, service: String, account: String) {
        lock.withLock { items[Key(service: service, account: account)] = data }
    }

    func script(_ operation: Operation, _ status: OSStatus) {
        lock.withLock { scripted[operation, default: []].append(status) }
    }

    func scriptCopyResult(status: OSStatus, result: CFTypeRef?) {
        lock.withLock { scriptedCopy.append((status, result)) }
    }

    var client: KeychainClient {
        KeychainClient(
            add: { [self] query in perform(.add, query) { key, query in
                if items[key] != nil { return errSecDuplicateItem }
                items[key] = query[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            update: { [self] query, changes in perform(.update, query) { key, _ in
                guard items[key] != nil else { return errSecItemNotFound }
                items[key] = (changes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            copyMatching: { [self] query in copy(query) },
            delete: { [self] query in perform(.delete, query) { key, _ in
                items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
            } }
        )
    }

    private func perform(
        _ operation: Operation,
        _ query: CFDictionary,
        _ body: (Key, [String: Any]) -> OSStatus
    ) -> OSStatus {
        lock.withLock {
            let query = Self.dictionary(query)
            recorded.append(Call(operation: operation, query: query))
            if var queue = scripted[operation], !queue.isEmpty {
                let status = queue.removeFirst()
                scripted[operation] = queue
                return status
            }
            return body(Self.key(query), query)
        }
    }

    private func copy(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        lock.withLock {
            let query = Self.dictionary(query)
            recorded.append(Call(operation: .copyMatching, query: query))
            if !scriptedCopy.isEmpty { return scriptedCopy.removeFirst() }
            guard let data = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as CFData)
        }
    }

    private static func dictionary(_ query: CFDictionary) -> [String: Any] {
        (query as NSDictionary) as? [String: Any] ?? [:]
    }

    private static func key(_ query: [String: Any]) -> Key {
        Key(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? ""
        )
    }
}
