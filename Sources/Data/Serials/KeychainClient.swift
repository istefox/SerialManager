import Foundation
import Security

/// Thin seam over the four SecItem functions, so `KeychainSerialStore` can be unit-tested
/// without touching the real Keychain. Production code uses `.live`; tests inject their own client.
struct KeychainClient: Sendable {
    var add: @Sendable (CFDictionary) -> OSStatus
    var update: @Sendable (_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
    var copyMatching: @Sendable (CFDictionary) -> (OSStatus, CFTypeRef?)
    var delete: @Sendable (CFDictionary) -> OSStatus

    /// The real Keychain.
    static let live = KeychainClient(
        add: { query in SecItemAdd(query, nil) },
        update: { query, attributes in SecItemUpdate(query, attributes) },
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query, &result)
            return (status, result)
        },
        delete: { query in SecItemDelete(query) }
    )
}
