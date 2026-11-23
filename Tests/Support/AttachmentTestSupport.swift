import CryptoKit
import Foundation
import os
import SwiftData
@testable import SerialManager

/// Fixtures for the attachment tests (SPEC 0018).
///
/// Every helper takes its own temporary directory and its own in-memory key store, so no test can
/// reach the real Attachments folder or the real Keychain (R9, R10, A18). Sample bytes are
/// obviously fake (R28).
enum AttachmentFixtures {
    /// Plaintext of a sample attachment. Obviously not a real license file.
    static func bytes(_ marker: String = "A") -> Data {
        Data("FAKE LICENSE FILE, NOT A REAL KEY. Sample \(marker).\n".utf8)
    }

    /// A deterministic key, so a test can seal bytes itself and compare.
    static func key(_ byte: UInt8 = 0x2A) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: byte, count: AttachmentKey.byteCount))
    }

    static func file(
        named name: String = "Sample-Pro.lic",
        contentType: String? = "public.data",
        bytes data: Data? = nil
    ) -> AttachmentFile {
        AttachmentFile(fileName: name, contentType: contentType, data: data ?? bytes())
    }

    static func imported(
        id: UUID,
        named name: String = "Sample-Pro.lic",
        contentType: String? = "public.data",
        addedAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000),
        bytes data: Data? = nil
    ) -> AttachmentImport {
        AttachmentImport(
            id: id, fileName: name, contentType: contentType, addedAt: addedAt,
            data: data ?? bytes())
    }

    static func summary(
        id: UUID,
        named name: String = "Sample-Pro.lic",
        byteCount: Int = 48,
        contentType: String? = "public.data",
        addedAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    ) -> AttachmentSummary {
        AttachmentSummary(
            id: id, fileName: name, byteCount: byteCount, contentType: contentType, addedAt: addedAt)
    }
}

/// A clock a test can move, safe to capture in a `@Sendable` closure.
final class AdvancingClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ start: Date) {
        state = OSAllocatedUnfairLock(initialState: start)
    }

    var date: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// A repository on an in-memory container with its own attachment directory and key store.
///
/// `directory.remove()` is the caller's job; the tests use a `defer`.
struct AttachmentHarness {
    let container: ModelContainer
    let directory: TemporaryDirectory
    let keys: InMemoryAttachmentKeyStore
    let serials: InMemorySerialStore
    let files: AttachmentFileStore
    let repository: SwiftDataLicenseRepository

    init(
        key: SymmetricKey? = AttachmentFixtures.key(),
        keyFailure: AttachmentError? = nil,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) }
    ) throws {
        container = try ModelContainer(
            for: License.self, AttachmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        directory = try TemporaryDirectory()
        keys = InMemoryAttachmentKeyStore(key: key, failure: keyFailure)
        serials = InMemorySerialStore()
        files = AttachmentFileStore(directory: directory.url, keys: keys)
        repository = SwiftDataLicenseRepository(
            modelContainer: container, serials: serials, attachments: files, now: now)
    }

    /// Bytes on disk for one attachment, as they really are: still sealed.
    func sealedBytes(of id: UUID) throws -> Data {
        try Data(contentsOf: files.url(for: id))
    }

    func fileExists(_ id: UUID) -> Bool { files.fileExists(id: id) }

    /// How many encrypted files the directory holds. The directory itself always exists, so a
    /// test that must prove "nothing was written" counts entries rather than checking the folder.
    var storedFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.url.path(percentEncoded: false)))?.count ?? 0
    }

    func remove() { directory.remove() }
}

extension AttachmentFileStore {
    /// A store under a fresh temporary path with an in-memory key, for the tests that must inject
    /// one but do not exercise attachments (R9, A18).
    ///
    /// Nothing is created on disk until something is written, so a test that attaches no file
    /// leaves no directory behind.
    static func unusedForTests() -> AttachmentFileStore {
        AttachmentFileStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "SerialManagerTests-unused-\(UUID().uuidString)", directoryHint: .isDirectory),
            keys: InMemoryAttachmentKeyStore(key: AttachmentFixtures.key())
        )
    }
}
