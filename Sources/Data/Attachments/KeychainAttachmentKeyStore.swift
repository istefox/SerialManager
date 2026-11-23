import CryptoKit
import Foundation
import Security

/// `AttachmentKeyStore` backed by the macOS data protection keychain, with the attributes ADR 0003
/// fixes for serials (ADR 0004, D3).
///
/// The key is a generic password item: service = `service` (the bundle identifier by default),
/// account = `Self.account`, a fixed name that is not a UUID, so it can never collide with a
/// license's serial item. Device-local (`WhenUnlockedThisDeviceOnly`), never synchronizable.
struct KeychainAttachmentKeyStore: AttachmentKeyStore {
    static let defaultService = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"
    /// Not a UUID string, so it cannot collide with a serial item of `KeychainSerialStore`, which
    /// shares the service.
    static let account = "attachment-key"

    let service: String
    private let client: KeychainClient

    init(service: String = Self.defaultService, client: KeychainClient = .live) {
        self.service = service
        self.client = client
    }

    func key() async throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = client.copyMatching(query as CFDictionary)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == AttachmentKey.byteCount else {
                throw AttachmentError.keyUndecodable
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AttachmentError.keyStatus(status)
        }
    }

    /// Adds the item. A duplicate means another caller won the race: the existing key is read back
    /// and returned, never overwritten (R10).
    func addKey(_ key: SymmetricKey) async throws -> SymmetricKey {
        var item = baseQuery()
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = client.add(item as CFDictionary)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            guard let existing = try await self.key() else { throw AttachmentError.keyMissing }
            return existing
        default:
            throw AttachmentError.keyStatus(status)
        }
    }

    /// Attributes shared by every call, so a flag can never differ between an add and a read.
    func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

extension AttachmentError {
    /// Maps a non-success Keychain status. `errSecItemNotFound` is handled by the callers, so it
    /// never reaches this mapping.
    static func keyStatus(_ status: OSStatus) -> AttachmentError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem:
            .keyAccessDenied
        case errSecDecode:
            .keyUndecodable
        default:
            // Includes errSecMissingEntitlement: a build or signing defect, not a user refusal.
            .keyUnexpected(status: status)
        }
    }
}
