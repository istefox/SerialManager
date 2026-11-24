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

    /// SM-02: files written by an earlier build carry `\/` for every slash. Both format versions
    /// still restore, and all six attachments come back byte for byte.
    @Test("Encrypted v1 and v2 backups with escaped slashes still import, attachments included")
    func escapedSlashBackupsImport() async throws {
        typealias J = BackupPayloadJSON
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // Version 1: no attachments, slashes escaped in the metadata and the serial.
        let v1ID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
        var v1Entry = J.entry(id: v1ID.uuidString, name: "Sample/Pro")
        v1Entry["serial"] = "FAKE/0000/0001"
        let v1Plain = try J.payload([v1Entry])
        #expect(String(decoding: v1Plain, as: UTF8.self).contains("\\/"))
        var v1File = BackupFileBuilder()
        v1File.version = 1
        let v1URL = directory.file("v1.smbackup")
        try v1File.sealed(v1Plain, password: password).write(to: v1URL)

        let oldTarget = try AttachmentHarness()
        defer { oldTarget.remove() }
        let v1Service = F.service(repository: oldTarget.repository)
        let v1Preview = try await v1Service.prepareImport(from: v1URL, password: password)
        _ = try await v1Service.applyImport(v1Preview, policy: .replace)
        let v1License = try #require(try await oldTarget.repository.fetchAll().first)
        #expect(v1License.productName == "Sample/Pro")
        #expect(try await oldTarget.repository.serial(for: v1License.id) == "FAKE/0000/0001")

        // Version 2: six high-slash attachments over two licenses.
        var blobs: [String: Data] = [:]
        var entries: [[String: Any]] = []
        for owner in 0..<2 {
            let ownerID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B\(owner)")!
            var attachments: [[String: Any]] = []
            for number in 0..<3 {
                let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 100 + owner * 10 + number))!
                var bytes = Data(repeating: 0xFF, count: 1_000_000)
                bytes[0] = UInt8(owner * 3 + number)
                blobs[id.uuidString] = bytes
                attachments.append([
                    "id": id.uuidString, "fileName": "Fake-\(owner)-\(number).bin",
                    "contentType": NSNull(), "byteCount": bytes.count,
                    "addedAt": "2026-01-01T09:00:00.250Z", "data": bytes.base64EncodedString(),
                ])
            }
            var entry = J.entry(id: ownerID.uuidString, name: "Sample \(owner)")
            entry["attachments"] = attachments
            entries.append(entry)
        }
        let v2Plain = try J.payload(entries)
        #expect(String(decoding: v2Plain, as: UTF8.self).contains("\\/"))
        var v2File = BackupFileBuilder()
        v2File.version = 2
        let v2URL = directory.file("v2.smbackup")
        try v2File.sealed(v2Plain, password: password).write(to: v2URL)
        #expect(try Data(contentsOf: v2URL).count <= BackupFormat.maxBackupFileSize)

        let target = try AttachmentHarness()
        defer { target.remove() }
        let service = F.service(repository: target.repository)
        let preview = try await service.prepareImport(from: v2URL, password: password)
        _ = try await service.applyImport(preview, policy: .replace)
        let restored = try await target.repository.fetchAll().flatMap(\.attachments)
        #expect(restored.count == 6)
        for attachment in restored {
            let expected = try #require(blobs[attachment.id.uuidString])
            #expect(try await target.repository.attachmentData(id: attachment.id) == expected)
        }
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

    /// SM-02: Base64 of 0xFF bytes is all slashes. With the optional `\/` escape on, six files of
    /// 4,500,000 bytes (27,000,000 plaintext, inside D3 and D4) encoded to about 72,000,000 bytes
    /// and the export failed with `fileTooLarge`; literal slashes keep it near 36,000,000.
    @Test("Six high-slash attachments within the limits export and restore under the 64 MiB cap")
    func highSlashAttachmentsFitTheCap() async throws {
        let source = try AttachmentHarness()
        defer { source.remove() }
        let target = try AttachmentHarness()
        defer { target.remove() }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()

        let owners = [
            try await source.repository.create(LicenseDraft(productName: "Sample Pro")),
            try await source.repository.create(LicenseDraft(productName: "Sample Lite")),
        ]
        let bytes = Data(repeating: 0xFF, count: 4_500_000)
        for (index, owner) in owners.enumerated() {
            for number in 1...3 {
                _ = try await source.repository.addAttachment(
                    AttachmentFile(
                        fileName: "Fake-\(index)-\(number).bin", contentType: nil, data: bytes),
                    to: owner.id)
            }
        }

        let summary = try await F.service(repository: source.repository)
            .export(to: url, password: password)
        #expect(summary.attachmentCount == 6)
        let fileSize = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)
        #expect(fileSize <= BackupFormat.maxBackupFileSize)
        #expect(fileSize < 40_000_000)

        let importer = F.service(repository: target.repository)
        let preview = try await importer.prepareImport(from: url, password: password)
        _ = try await importer.applyImport(preview, policy: .replace)
        let restored = try await target.repository.fetchAll().flatMap(\.attachments)
        #expect(restored.count == 6)
        let sample = try #require(restored.first)
        #expect(try await target.repository.attachmentData(id: sample.id) == bytes)
    }

    /// SM-02: the encoder writes literal slashes, and a backup that still carries `\/` (written
    /// before this change) decodes to the same bytes.
    @Test("Literal and escaped slashes in the Base64 decode to the same attachment")
    func escapedSlashesStillDecode() throws {
        let id = UUID()
        let raw = Data([0xFF, 0xFE, 0xFD, 0xFF, 0xFF, 0xFF])
        let literal = raw.base64EncodedString()
        #expect(literal.contains("/"))
        let attachment = BackupPayload.Attachment(
            id: id, fileName: "Fake.bin", contentType: nil, byteCount: raw.count,
            addedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), data: raw)

        let encoded = try BackupPayload.makeEncoder().encode(attachment)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("\"data\":\"\(literal)\""))
        #expect(!text.contains("\\/"))

        let escaped = text.replacingOccurrences(of: "/", with: "\\/")
        let decoded = try BackupPayload.makeDecoder()
            .decode(BackupPayload.Attachment.self, from: Data(escaped.utf8))
        #expect(decoded.data == raw)
        #expect(decoded.id == id)
    }

    /// File names of every attachment inside the backup at `url`.
    private func exportedAttachmentNames(at url: URL) throws -> [String] {
        let plaintext = try BackupFileReader.decrypt(
            try Data(contentsOf: url), password: password).plaintext
        let payload = try BackupPayload.makeDecoder().decode(BackupPayload.self, from: plaintext)
        return payload.licenses.flatMap { $0.attachments.map(\.fileName) }
    }
}
