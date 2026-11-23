import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Attachments through the real `EncryptedBackupService` (SPEC 0018, A13 to A15, A17).
///
/// Real service, real repository on an in-memory container, real key derivation at 600,000
/// iterations. Every attachment directory and key store is injected, so nothing touches the real
/// Keychain or the real Application Support folder (A18). Sample bytes are obviously fake (R28).
@MainActor
struct AttachmentBackupTests {
    private typealias F = BackupFixtures
    private typealias J = BackupPayloadJSON

    private let password = "sample-backup-paSS"

    /// Base64 of one plaintext, the way the payload carries it.
    private func base64(_ data: Data) -> String { data.base64EncodedString() }

    /// A version 2 attachment object for a hand-built payload.
    private func entryAttachment(
        id: String,
        fileName: String = "Sample-Pro.lic",
        contentType: Any = "public.data",
        byteCount: Int,
        addedAt: String = "2026-01-01T08:00:00.000Z",
        data: String
    ) -> [String: Any] {
        [
            "id": id, "fileName": fileName, "contentType": contentType,
            "byteCount": byteCount, "addedAt": addedAt, "data": data,
        ]
    }

    // MARK: A13: the round trip

    @Test("Export then import carries every attachment field and byte unchanged")
    func roundTrip() async throws {
        let source = try AttachmentHarness()
        defer { source.remove() }
        let target = try AttachmentHarness()
        defer { target.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        let owner = try await source.repository.create(
            LicenseDraft(productName: "Sample Pro", vendor: "Sample Vendor", serial: "FAKE-0000-0001"))
        let other = try await source.repository.create(LicenseDraft(productName: "Sample Lite"))
        let firstBytes = AttachmentFixtures.bytes("one")
        let secondBytes = AttachmentFixtures.bytes("two")
        _ = try await source.repository.addAttachment(
            AttachmentFile(fileName: "Licence.lic", contentType: "public.data", data: firstBytes),
            to: owner.id)
        _ = try await source.repository.addAttachment(
            AttachmentFile(fileName: "Invoice.pdf", contentType: nil, data: secondBytes),
            to: owner.id)
        let expected = try #require(try await source.repository.fetchAll()
            .first { $0.id == owner.id }).attachments
        #expect(expected.count == 2)
        #expect(try await source.repository.fetchAll().first { $0.id == other.id }?
            .attachments.isEmpty == true)

        let exporter = F.service(repository: source.repository)
        let summary = try await exporter.export(to: url, password: password)
        #expect(summary.licenseCount == 2)
        #expect(summary.attachmentCount == 2)
        #expect(summary.missingAttachmentCount == 0)

        let importer = F.service(repository: target.repository)
        let preview = try await importer.prepareImport(from: url, password: password)
        _ = try await importer.applyImport(preview, policy: .replace)

        let imported = try #require(try await target.repository.fetchAll()
            .first { $0.id == owner.id })
        #expect(imported.attachments.count == 2)
        for (original, copy) in zip(expected, imported.attachments) {
            #expect(copy.id == original.id)
            #expect(copy.fileName == original.fileName)
            #expect(copy.contentType == original.contentType)
            #expect(copy.byteCount == original.byteCount)
            #expect(copy.addedAt == original.addedAt)
        }
        // The bytes themselves, decrypted under the TARGET library's own key.
        let byName = Dictionary(
            uniqueKeysWithValues: imported.attachments.map { ($0.fileName, $0.id) })
        #expect(try await target.repository
            .attachmentData(id: try #require(byName["Licence.lic"])) == firstBytes)
        #expect(try await target.repository
            .attachmentData(id: try #require(byName["Invoice.pdf"])) == secondBytes)
        // And the file on disk in the target library is sealed, not a plain copy.
        #expect(try target.sealedBytes(of: try #require(byName["Licence.lic"])) != firstBytes)
    }

    // MARK: Export with an attachment whose file is gone (decided by Stefano, 2026-11-23)

    @Test("An attachment whose stored file is gone is skipped and counted, not a failure")
    func missingFileIsSkippedAndCounted() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        let owner = try await harness.repository.create(LicenseDraft(productName: "Sample Pro"))
        let kept = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Kept.lic"), to: owner.id).attachments.first)
        let lost = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Lost.lic"), to: owner.id).attachments
            .first { $0.fileName == "Lost.lic" })
        // The file disappears behind the app's back; R13 allows the row to stay.
        try FileManager.default.removeItem(at: harness.files.url(for: lost.id))

        let summary = try await F.service(repository: harness.repository)
            .export(to: url, password: password)

        #expect(summary.licenseCount == 1)
        #expect(summary.attachmentCount == 1)
        #expect(summary.missingAttachmentCount == 1)

        // The backup holds the readable one and nothing of the lost one.
        let names = try await exportedAttachmentNames(at: url)
        #expect(names == ["Kept.lic"])
        #expect(kept.fileName == "Kept.lic")
    }

    @Test("A decryption failure aborts the export instead of skipping")
    func decryptionFailureAborts() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        let owner = try await harness.repository.create(LicenseDraft(productName: "Sample Pro"))
        let attachment = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(), to: owner.id).attachments.first)
        // The file is there but its bytes no longer authenticate: a symptom, not missing data.
        try Data(repeating: 0x00, count: 64).write(to: harness.files.url(for: attachment.id))

        await #expect(throws: AttachmentError.decryptionFailed) {
            try await F.service(repository: harness.repository)
                .export(to: url, password: password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: A14: a version 1 file still imports

    @Test("A version 1 backup imports and its licenses have no attachments")
    func versionOneStillImports() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        var builder = BackupFileBuilder()
        builder.version = 1
        // A version 1 entry has no `attachments` key at all, which is what `J.entry()` builds.
        let entry = J.entry()
        try builder.sealed(try J.payload(entries: [entry]), password: password)
            .write(to: url)

        let service = F.service(repository: harness.repository)
        let preview = try await service.prepareImport(from: url, password: password)
        #expect(preview.licenseCount == 1)
        let result = try await service.applyImport(preview, policy: .replace)
        #expect(result.imported == 1)

        let imported = try #require(try await harness.repository.fetchAll().first)
        #expect(imported.productName == "Sample Editor")
        #expect(imported.attachments.isEmpty)
        #expect(harness.storedFileCount == 0)
        // No key was ever needed, so none was generated (R10).
        #expect(await harness.keys.addCount == 0)
    }

    // MARK: A15: malformed attachment payloads are corrupted files

    @Test("Malformed base64, a length mismatch, a blank name and a duplicate id are all corrupted")
    func malformedAttachmentsAreCorrupted() async throws {
        let plaintext = AttachmentFixtures.bytes()
        let sharedID = "00000000-0000-4000-8000-0000000000A1"
        let cases: [(String, [[String: Any]])] = [
            (
                "base64 that does not decode",
                [entryAttachment(id: sharedID, byteCount: plaintext.count, data: "not base64 at all!!")]
            ),
            (
                "a decoded length that disagrees with byteCount",
                [entryAttachment(id: sharedID, byteCount: plaintext.count + 1, data: base64(plaintext))]
            ),
            (
                "a blank file name",
                [entryAttachment(
                    id: sharedID, fileName: "   ", byteCount: plaintext.count, data: base64(plaintext))]
            ),
            (
                "a negative byteCount",
                [entryAttachment(id: sharedID, byteCount: -1, data: base64(plaintext))]
            ),
            (
                "the same attachment id twice in one file",
                [
                    entryAttachment(id: sharedID, byteCount: plaintext.count, data: base64(plaintext)),
                    entryAttachment(
                        id: sharedID, fileName: "Other.lic", byteCount: plaintext.count,
                        data: base64(plaintext)),
                ]
            ),
        ]

        for (label, attachments) in cases {
            let harness = try AttachmentHarness()
            defer { harness.remove() }
            let directory = try TemporaryDirectory()
            defer { directory.remove() }
            let url = directory.file()
            var entry = J.entry()
            entry["attachments"] = attachments
            try BackupFileBuilder()
                .sealed(try J.payload(entries: [entry]), password: password)
                .write(to: url)

            await #expect(throws: BackupError.corruptedFile, "\(label) must be a corrupted file") {
                try await F.service(repository: harness.repository)
                    .prepareImport(from: url, password: password)
            }
            // A rejected file writes nothing at all (SPEC 0010, R4).
            #expect(try await harness.repository.fetchAll().isEmpty)
            #expect(harness.storedFileCount == 0)
        }
    }

    @Test("The same attachment id on two different licenses is still a corrupted file")
    func duplicateIDAcrossLicensesIsCorrupted() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()
        let plaintext = AttachmentFixtures.bytes()
        let sharedID = "00000000-0000-4000-8000-0000000000A1"

        // One attachment id means one file on disk, so two licenses may not share one.
        var first = J.entry(id: J.editorID, name: "Sample Editor")
        first["attachments"] = [
            entryAttachment(id: sharedID, byteCount: plaintext.count, data: base64(plaintext))
        ]
        var second = J.entry(id: J.viewerID, name: "Sample Viewer")
        second["attachments"] = [
            entryAttachment(
                id: sharedID, fileName: "Other.lic", byteCount: plaintext.count,
                data: base64(plaintext))
        ]
        try BackupFileBuilder()
            .sealed(try J.payload(entries: [first, second]), password: password)
            .write(to: url)

        await #expect(throws: BackupError.corruptedFile) {
            try await F.service(repository: harness.repository)
                .prepareImport(from: url, password: password)
        }
    }

    // MARK: A17: attachments can push a backup over the 64 MiB cap

    @Test("A backup over the size cap fails with fileTooLarge and writes no file")
    func oversizedBackupWritesNothing() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        let owner = try await harness.repository.create(LicenseDraft(productName: "Sample Pro"))
        _ = try await harness.repository.addAttachment(
            AttachmentFile(
                fileName: "Big.bin", contentType: nil,
                data: Data(repeating: 0x5A, count: 5_000_000)),
            to: owner.id)

        // A cap small enough that the base64 of one attachment already passes it.
        let service = F.service(repository: harness.repository, maxFileSize: 1_000_000)
        await #expect(throws: BackupExportError.fileTooLarge) {
            try await service.export(to: url, password: password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// File names of every attachment inside the backup at `url`.
    private func exportedAttachmentNames(at url: URL) throws -> [String] {
        let plaintext = try BackupFileReader.decrypt(
            try Data(contentsOf: url), password: password).plaintext
        let payload = try BackupPayload.makeDecoder().decode(BackupPayload.self, from: plaintext)
        return payload.licenses.flatMap { $0.attachments.map(\.fileName) }
    }
}
