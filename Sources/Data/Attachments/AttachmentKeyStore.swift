import CryptoKit
import Foundation

/// Stores the one library-wide key that encrypts every attachment (SPEC 0018, D7; ADR 0004).
///
/// Internal to the data layer. Read and add only: there is no update and no delete path, because
/// replacing the key would make every file already stored permanently unreadable (R10).
protocol AttachmentKeyStore: Sendable {
    /// The stored key, or nil when no key item exists.
    /// - Throws: `AttachmentError.keyAccessDenied`, `.keyUndecodable` or `.keyUnexpected`.
    func key() async throws -> SymmetricKey?
    /// Adds the key item. When one already exists, returns the existing key instead of replacing
    /// it: two callers racing to create the first key must end up with the same key.
    /// - Throws: `AttachmentError.keyAccessDenied`, `.keyUndecodable` or `.keyUnexpected`.
    func addKey(_ key: SymmetricKey) async throws -> SymmetricKey
}

/// Number of bytes of the library key: AES-256.
enum AttachmentKey {
    static let byteCount = 32

    static func random() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }
}
