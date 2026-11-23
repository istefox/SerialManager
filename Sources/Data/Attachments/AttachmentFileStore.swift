import CryptoKit
import Foundation

/// Reads and writes the encrypted bytes of each attachment (ADR 0004, D1 and D2).
///
/// One file per attachment at `<directory>/<attachment id>`, sealed with AES-256-GCM under the
/// library key. The file name on disk is the attachment's UUID, never the user's file name: a
/// folder listing must not leak which software the owner owns (R9).
///
/// `directory` is a constructor parameter with a production default, exactly as
/// `KeychainSerialStore.service` is (ADR 0003, decision 2). Debug and Release share one bundle
/// identifier, so no test and no preview may ever be able to reach the real folder.
///
/// Sendable and free of state: `SwiftDataLicenseRepository` calls it from its actor, so the
/// encryption runs off the main actor.
struct AttachmentFileStore: Sendable {
    let directory: URL
    private let keys: any AttachmentKeyStore

    /// No default for `keys`: a default of the real Keychain store would let a test that only
    /// overrides `directory` create or read the real library key (R10, A18). `LicenseLibrary` is
    /// the single place that passes `KeychainAttachmentKeyStore`.
    init(directory: URL, keys: any AttachmentKeyStore) {
        self.directory = directory
        self.keys = keys
    }

    /// The library key.
    ///
    /// - Parameter generateIfMissing: pass true only when the caller has just established that the
    ///   library holds no attachment. A not-found answer then creates the first key; otherwise it
    ///   throws `.keyMissing`. Any other Keychain failure throws and never generates a key (R10).
    func key(generateIfMissing: Bool) async throws -> SymmetricKey {
        if let existing = try await keys.key() { return existing }
        guard generateIfMissing else { throw AttachmentError.keyMissing }
        return try await keys.addKey(AttachmentKey.random())
    }

    /// Seals `plaintext` and writes it at `<directory>/<id>`, creating the directory if needed.
    ///
    /// Overwrites atomically, so a half-written file is never left behind.
    /// - Throws: `AttachmentError.encryptionFailed`, a key error, or the file write error unchanged.
    func write(_ plaintext: Data, id: UUID, key: SymmetricKey) throws {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw AttachmentError.encryptionFailed
        }
        // `combined` is nil only for a nonce that is not 12 bytes; AES.GCM.seal uses one that is.
        guard let sealed = box.combined else { throw AttachmentError.encryptionFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.write(to: url(for: id), options: .atomic)
    }

    /// The plaintext of the attachment stored under `id`.
    /// - Throws: `AttachmentError.fileMissing` when the file is gone (R13),
    ///   `.decryptionFailed` when the bytes do not authenticate, or a key error.
    func read(id: UUID, key: SymmetricKey) throws -> Data {
        let fileURL = url(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw AttachmentError.fileMissing(id)
        }
        let sealed = try Data(contentsOf: fileURL)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        } catch {
            throw AttachmentError.decryptionFailed
        }
    }

    /// Removes the file of `id`. Succeeds when it is already gone.
    func delete(id: UUID) throws {
        let fileURL = url(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// True when a file exists for `id`. Used to show an attachment whose file is missing as
    /// unreadable without decrypting anything (R13).
    func fileExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path(percentEncoded: false))
    }

    func url(for id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .notDirectory)
    }
}
