import CryptoKit
import Foundation

/// In-memory `AttachmentKeyStore` for previews and tests. Not used in production.
///
/// Every test injects one of these, so no test ever reads or writes the real Keychain
/// (SPEC 0018, R10 and A18).
actor InMemoryAttachmentKeyStore: AttachmentKeyStore {
    private var stored: SymmetricKey?
    private var failure: AttachmentError?
    /// How many times `key()` and `addKey(_:)` were called, so a test can prove that an existing
    /// key is read and never written (A12).
    private(set) var readCount = 0
    private(set) var addCount = 0

    /// - Parameters:
    ///   - key: the key already in the store; nil makes `key()` answer not-found.
    ///   - failure: thrown by both calls instead of answering, for the access-denied case.
    init(key: SymmetricKey? = nil, failure: AttachmentError? = nil) {
        self.stored = key
        self.failure = failure
    }

    func key() async throws -> SymmetricKey? {
        readCount += 1
        if let failure { throw failure }
        return stored
    }

    func addKey(_ key: SymmetricKey) async throws -> SymmetricKey {
        addCount += 1
        if let failure { throw failure }
        if let stored { return stored }
        stored = key
        return key
    }

    /// The key currently held, without counting as a read.
    var storedKey: SymmetricKey? { stored }

    /// Drops the key as if the Keychain item had been lost, so a test can prove the app refuses
    /// to mint a replacement while files remain on disk (A12, R10).
    func forget() {
        stored = nil
    }
}
