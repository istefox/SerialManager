import Foundation
import Security

/// `SerialStore` backed by the macOS data protection keychain (ADR 0001, ADR 0002).
///
/// Each serial is a generic password item: service = `service` (the bundle identifier by default),
/// account = the license UUID string. Items are device-local (`WhenUnlockedThisDeviceOnly`) and
/// never synchronizable. The value is stored as UTF-8 bytes, exactly as given.
struct KeychainSerialStore: SerialStore {
    static let defaultService = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"

    let service: String
    private let client: KeychainClient

    init(service: String = Self.defaultService, client: KeychainClient = .live) {
        self.service = service
        self.client = client
    }

    /// Stores `serial` for `id`, replacing any existing value, so exactly one item exists per UUID.
    ///
    /// Tries an update first; when no item exists, adds one. If the add reports a duplicate
    /// (a concurrent save won the race), it updates once more. Known edge: if a concurrent delete
    /// removes the item between that add and the second update, the update returns
    /// `errSecItemNotFound` and save throws `.unexpected(status: -25300)`. Accepted: the consumer
    /// serialises its own operations per license, and the error is surfaced, not swallowed.
    func save(_ serial: String, for id: UUID) async throws {
        let query = baseQuery(for: id) as CFDictionary
        let data = Data(serial.utf8)
        let changes = [kSecValueData as String: data] as CFDictionary

        var status = client.update(query, changes)
        if status == errSecItemNotFound {
            var item = baseQuery(for: id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = client.add(item as CFDictionary)
            if status == errSecDuplicateItem {
                status = client.update(query, changes)
            }
        }
        guard status == errSecSuccess else { throw SerialStoreError(status: status) }
    }

    /// Returns nil when no item exists for `id`.
    func serial(for id: UUID) async throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = client.copyMatching(query as CFDictionary)
        switch status {
        case errSecSuccess:
            // Validate with the failable initializer, then decode with String(decoding:as:):
            // String(data:encoding:) drops a leading U+FEFF, which would break the round-trip.
            guard let data = result as? Data, String(data: data, encoding: .utf8) != nil else {
                throw SerialStoreError.undecodableData
            }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SerialStoreError(status: status)
        }
    }

    /// Succeeds when no item exists for `id`.
    func deleteSerial(for id: UUID) async throws {
        let status = client.delete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SerialStoreError(status: status)
        }
    }

    /// Attributes shared by every call (add, update, copy, delete), so a flag can never differ
    /// between calls. Internal so the Debug smoke check inspects exactly the same items.
    func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

extension SerialStoreError {
    /// Maps a non-success Keychain status to an error. Read and delete handle
    /// `errSecItemNotFound` themselves, so it never reaches this mapping from them.
    init(status: OSStatus) {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem:
            self = .accessDenied
        case errSecDecode:
            self = .undecodableData
        default:
            // Includes errSecMissingEntitlement: a build or signing defect, not a user refusal.
            self = .unexpected(status: status)
        }
    }
}
