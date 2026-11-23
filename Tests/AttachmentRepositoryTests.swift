import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Attachments through the real `SwiftDataLicenseRepository` (SPEC 0018, A5 to A12, A16).
///
/// Every test builds its own `AttachmentHarness`: in-memory SwiftData container, in-memory serial
/// store, in-memory key store, temporary attachments directory. No test reads or writes the real
/// Keychain or the real Application Support folder (A18), and every sample byte is obviously fake
/// (R28).
@MainActor
struct AttachmentRepositoryTests {
    private struct PersistFailure: Error, Equatable {}

    private let t = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func license(
        _ repository: SwiftDataLicenseRepository, named name: String = "Sample Pro"
    ) async throws -> LicenseSummary {
        try await repository.create(LicenseDraft(productName: name, vendor: "Sample Vendor"))
    }

    // MARK: A5, A6: one row, one file, really encrypted, and it reads back

    @Test("Adding writes one row and one file whose bytes are not the plaintext")
    func addEncrypts() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let plaintext = AttachmentFixtures.bytes()

        let saved = try await harness.repository.addAttachment(
            AttachmentFixtures.file(bytes: plaintext), to: owner.id)

        #expect(saved.attachments.count == 1)
        let attachment = try #require(saved.attachments.first)
        #expect(attachment.fileName == "Sample-Pro.lic")
        #expect(attachment.byteCount == plaintext.count)
        #expect(attachment.addedAt == t)
        #expect(harness.fileExists(attachment.id))

        // The point of A5: a plain copy would pass a round trip, so compare the real bytes.
        let onDisk = try harness.sealedBytes(of: attachment.id)
        #expect(onDisk != plaintext)
        #expect(!onDisk.isEmpty)
        // AES-GCM combined form: 12-byte nonce plus ciphertext plus 16-byte tag.
        #expect(onDisk.count == plaintext.count + 28)
        // And the plaintext does not appear anywhere inside the sealed bytes.
        #expect(onDisk.range(of: plaintext) == nil)

        // A6: exactly the original bytes come back.
        #expect(try await harness.repository.attachmentData(id: attachment.id) == plaintext)
        // One row only, and one file only.
        let rows = try ModelContext(harness.container).fetch(FetchDescriptor<AttachmentRecord>())
        #expect(rows.count == 1)
        #expect(harness.storedFileCount == 1)
    }

    // MARK: A7: the three limits, in decimal bytes

    @Test("A file of 5,000,001 bytes is refused and nothing is written")
    func perFileLimit() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let tooBig = AttachmentFile(
            fileName: "Too-Big.bin", contentType: nil, data: Data(repeating: 0x5A, count: 5_000_001))

        await #expect(throws: AttachmentError.fileTooLarge(
            fileName: "Too-Big.bin", limit: AttachmentLimits.maxFileBytes)) {
            try await harness.repository.addAttachment(tooBig, to: owner.id)
        }
        #expect(try await harness.repository.fetchAll().first?.attachments.isEmpty == true)
        #expect(harness.storedFileCount == 0)
        // Exactly at the limit it is accepted, so the test pins 5,000,001 and not 5 MiB.
        let atLimit = AttachmentFile(
            fileName: "At-Limit.bin", contentType: nil,
            data: Data(repeating: 0x5A, count: AttachmentLimits.maxFileBytes))
        #expect(try await harness.repository.addAttachment(atLimit, to: owner.id)
            .attachments.count == 1)
    }

    @Test("20,000,001 bytes on one license is refused at the file that crosses the limit")
    func perLicenseLimit() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        // Four files of 5,000,000 reach exactly 20,000,000: the fifth byte over is refused.
        for index in 1...4 {
            let file = AttachmentFile(
                fileName: "Part-\(index).bin", contentType: nil,
                data: Data(repeating: UInt8(index), count: 5_000_000))
            _ = try await harness.repository.addAttachment(file, to: owner.id)
        }
        let crossing = AttachmentFile(
            fileName: "Crossing.bin", contentType: nil, data: Data(repeating: 0x09, count: 1))

        await #expect(throws: AttachmentError.licenseLimitExceeded(
            fileName: "Crossing.bin", limit: AttachmentLimits.maxLicenseBytes)) {
            try await harness.repository.addAttachment(crossing, to: owner.id)
        }
        // Everything added before the refusal is still there.
        let after = try #require(try await harness.repository.fetchAll().first)
        #expect(after.attachments.count == 4)
        #expect(after.attachmentBytes == 20_000_000)
    }

    @Test("The 40,000,000-byte library total is enforced across licenses")
    func libraryLimit() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        // Two licenses at 20,000,000 each fill the library total exactly.
        var owners: [LicenseSummary] = []
        for name in ["Sample Pro", "Sample Lite"] {
            let owner = try await license(harness.repository, named: name)
            owners.append(owner)
            for index in 1...4 {
                let file = AttachmentFile(
                    fileName: "\(name)-\(index).bin", contentType: nil,
                    data: Data(repeating: UInt8(index), count: 5_000_000))
                _ = try await harness.repository.addAttachment(file, to: owner.id)
            }
        }
        let third = try await license(harness.repository, named: "Sample Extra")
        let crossing = AttachmentFile(
            fileName: "Crossing.bin", contentType: nil, data: Data(repeating: 0x09, count: 1))

        await #expect(throws: AttachmentError.libraryLimitExceeded(
            fileName: "Crossing.bin", limit: AttachmentLimits.maxLibraryBytes)) {
            try await harness.repository.addAttachment(crossing, to: third.id)
        }
        let all = try await harness.repository.fetchAll()
        #expect(all.reduce(0) { $0 + $1.attachmentBytes } == 40_000_000)
        #expect(all.first { $0.id == third.id }?.attachments.isEmpty == true)
    }

    // MARK: A8: a failure after the file is written leaves no row and no file

    @Test("A persist failure after the write leaves neither a row nor a file")
    func compensatesAfterWrite() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        // A second repository on the same container and the same attachment directory, whose save
        // throws: the file is written, then the save fails.
        let failing = SwiftDataLicenseRepository(
            modelContainer: harness.container,
            serials: harness.serials,
            attachments: harness.files,
            now: { self.t },
            beforeSave: { throw PersistFailure() }
        )

        await #expect(throws: PersistFailure()) {
            try await failing.addAttachment(AttachmentFixtures.file(), to: owner.id)
        }

        // The invariant: no row points at a missing file, and no file is left without a row.
        let rows = try ModelContext(harness.container).fetch(FetchDescriptor<AttachmentRecord>())
        #expect(rows.isEmpty)
        #expect(harness.storedFileCount == 0)
        #expect(try await harness.repository.fetchAll().first?.attachments.isEmpty == true)
    }

    // MARK: A9: deleting a license deletes its rows and its files

    @Test("Deleting a license deletes every row and every file of that license only")
    func deleteRemovesFiles() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let other = try await license(harness.repository, named: "Sample Lite")
        let doomed = try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Doomed.lic"), to: owner.id).attachments
        let kept = try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Kept.lic"), to: other.id).attachments
        #expect(doomed.count == 1)
        #expect(kept.count == 1)

        try await harness.repository.delete(id: owner.id)

        for attachment in doomed { #expect(!harness.fileExists(attachment.id)) }
        for attachment in kept { #expect(harness.fileExists(attachment.id)) }
        let rows = try ModelContext(harness.container).fetch(FetchDescriptor<AttachmentRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.licenseID == other.id)
    }

    // MARK: A10: both directions of an orphan

    @Test("A row whose file is gone is unreadable and removable; a file with no row is left alone")
    func orphansBothWays() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let attachment = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(), to: owner.id).attachments.first)

        // Direction 1: the file is removed behind the app's back.
        try FileManager.default.removeItem(at: harness.files.url(for: attachment.id))
        #expect(await harness.repository.attachmentIsReadable(id: attachment.id) == false)
        await #expect(throws: AttachmentError.fileMissing(attachment.id)) {
            try await harness.repository.attachmentData(id: attachment.id)
        }
        // It still removes cleanly, with no crash.
        let after = try await harness.repository.removeAttachment(id: attachment.id)
        #expect(after.attachments.isEmpty)

        // Direction 2: a file with no row must be LEFT where it is. R13 forbids the sweep.
        let orphanID = UUID()
        try harness.files.write(
            AttachmentFixtures.bytes("orphan"), id: orphanID, key: AttachmentFixtures.key())
        _ = try await harness.repository.fetchAll()
        let second = try await license(harness.repository, named: "Sample Lite")
        _ = try await harness.repository.addAttachment(AttachmentFixtures.file(), to: second.id)
        try await harness.repository.delete(id: second.id)
        #expect(harness.fileExists(orphanID), "a file with no row must not be deleted (R13)")
    }

    // MARK: A11: who bumps updatedAt

    @Test("Adding and removing bump updatedAt; importing does not")
    func updatedAtRules() async throws {
        let clock = AdvancingClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let harness = try AttachmentHarness(now: { clock.date })
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        #expect(owner.updatedAt == clock.date)

        clock.advance(by: 60)
        let added = try await harness.repository.addAttachment(AttachmentFixtures.file(), to: owner.id)
        #expect(added.updatedAt == clock.date)
        #expect(added.createdAt == owner.createdAt)

        clock.advance(by: 60)
        let removed = try await harness.repository.removeAttachment(
            id: try #require(added.attachments.first).id)
        #expect(removed.updatedAt == clock.date)

        // An import keeps both dates from the backup, attachments included (SPEC 0010 D3, R25).
        clock.advance(by: 60)
        let backupDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var record = LicenseSummary(
            id: UUID(), productName: "Imported Pro", vendor: "", registeredName: "",
            registeredEmail: "", purchaseDate: nil, version: "", notes: "",
            createdAt: backupDate, updatedAt: backupDate)
        record.attachments = []
        let outcome = try await harness.repository.importLicense(
            record, serial: nil,
            attachments: [AttachmentFixtures.imported(id: UUID(), addedAt: backupDate)],
            policy: .skip)
        #expect(outcome == .created)
        let imported = try #require(try await harness.repository.fetchAll()
            .first { $0.id == record.id })
        #expect(imported.updatedAt == backupDate)
        #expect(imported.createdAt == backupDate)
        #expect(imported.attachments.first?.addedAt == backupDate)
    }

    // MARK: A12: the key store, three cases

    @Test("An existing key is read, never written")
    func keyIsReadWhenPresent() async throws {
        let harness = try AttachmentHarness(key: AttachmentFixtures.key())
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        _ = try await harness.repository.addAttachment(AttachmentFixtures.file(), to: owner.id)

        #expect(await harness.keys.addCount == 0)
        #expect(await harness.keys.readCount >= 1)
    }

    @Test("A key is generated only on not-found with no attachment stored")
    func keyIsGeneratedOnce() async throws {
        let harness = try AttachmentHarness(key: nil)
        defer { harness.remove() }
        let owner = try await license(harness.repository)

        let first = try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "First.lic"), to: owner.id)
        #expect(first.attachments.count == 1)
        #expect(await harness.keys.addCount == 1)

        // The library now holds an attachment, so the second add must not generate anything.
        _ = try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Second.lic"), to: owner.id)
        #expect(await harness.keys.addCount == 1)
    }

    @Test("Access denied throws and generates no key")
    func keyAccessDeniedGeneratesNothing() async throws {
        let harness = try AttachmentHarness(key: nil, keyFailure: .keyAccessDenied)
        defer { harness.remove() }
        let owner = try await license(harness.repository)

        await #expect(throws: AttachmentError.keyAccessDenied) {
            try await harness.repository.addAttachment(AttachmentFixtures.file(), to: owner.id)
        }
        #expect(await harness.keys.addCount == 0)
        #expect(await harness.keys.storedKey == nil)
        // Nothing written: no row, no file.
        #expect(try ModelContext(harness.container)
            .fetch(FetchDescriptor<AttachmentRecord>()).isEmpty)
        #expect(harness.storedFileCount == 0)
    }

    @Test("With attachments stored, a missing key throws instead of being replaced")
    func missingKeyIsNeverReplaced() async throws {
        let harness = try AttachmentHarness(key: AttachmentFixtures.key())
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        _ = try await harness.repository.addAttachment(AttachmentFixtures.file(), to: owner.id)

        // The key disappears from the store while a file remains on disk: silently minting a new
        // one would make every stored file unreadable forever (R10).
        await harness.keys.forget()
        await #expect(throws: AttachmentError.keyMissing) {
            try await harness.repository.addAttachment(
                AttachmentFixtures.file(named: "Second.lic"), to: owner.id)
        }
        #expect(await harness.keys.addCount == 0)
    }

    // MARK: A16: import merges, never deletes, and ignores the limits

    @Test("Skip changes no local attachment")
    func importSkipChangesNothing() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let local = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Local.lic"), to: owner.id).attachments.first)

        let outcome = try await harness.repository.importLicense(
            try #require(try await harness.repository.fetchAll().first),
            serial: nil,
            attachments: [AttachmentFixtures.imported(id: UUID(), named: "FromBackup.lic")],
            policy: .skip)

        #expect(outcome == .skipped)
        let after = try #require(try await harness.repository.fetchAll().first)
        #expect(after.attachments.map(\.fileName) == ["Local.lic"])
        #expect(harness.fileExists(local.id))
        #expect(harness.storedFileCount == 1)
    }

    @Test("Replace merges by id, keeps a local attachment absent from the backup, and ignores the library total")
    func importReplaceMerges() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        // 40,000,000 bytes stored, four files on each of two licenses: the library total is full
        // and neither license is over its own 20,000,000 (A7).
        let owner = try await license(harness.repository)
        let second = try await license(harness.repository, named: "Sample Lite")
        for (owner, prefix) in [(owner, "Pro"), (second, "Lite")] {
            for index in 1...4 {
                let file = AttachmentFile(
                    fileName: "\(prefix)-\(index).bin", contentType: nil,
                    data: Data(repeating: UInt8(index), count: 5_000_000))
                _ = try await harness.repository.addAttachment(file, to: owner.id)
            }
        }
        let all = try await harness.repository.fetchAll()
        #expect(all.reduce(0) { $0 + $1.attachmentBytes } == 40_000_000)
        let stored = try #require(all.first { $0.id == owner.id })
        #expect(stored.attachmentBytes == 20_000_000)
        let shared = try #require(stored.attachments.first)
        let newID = UUID()

        // The backup carries the id of an attachment already present plus a brand new one, and the
        // result goes over the library total. An import never refuses for a limit (R25).
        let outcome = try await harness.repository.importLicense(
            stored, serial: nil,
            attachments: [
                AttachmentFixtures.imported(
                    id: shared.id, named: "Renamed-In-Backup.lic", bytes: AttachmentFixtures.bytes("b")),
                AttachmentFixtures.imported(id: newID, named: "New-From-Backup.lic"),
            ],
            policy: .replace)

        #expect(outcome == .replaced)
        let after = try #require(try await harness.repository.fetchAll().first { $0.id == owner.id })
        // Five attachments: the four local ones plus the one new id. Nothing was deleted.
        #expect(after.attachments.count == 5)
        #expect(after.attachments.contains { $0.id == newID })
        // The library total is now past its ceiling, and the import was right not to refuse (R25).
        #expect(try await harness.repository.fetchAll().reduce(0) { $0 + $1.attachmentBytes }
            > AttachmentLimits.maxLibraryBytes)
        // The id already present was left exactly as it was: not renamed, not rewritten.
        let unchanged = try #require(after.attachments.first { $0.id == shared.id })
        #expect(unchanged.fileName == shared.fileName)
        #expect(unchanged.byteCount == shared.byteCount)
        #expect(try await harness.repository.attachmentData(id: shared.id).count == shared.byteCount)
        #expect(try await harness.repository.attachmentData(id: newID) == AttachmentFixtures.bytes())
    }

    @Test("An import that fails part way deletes only the files it wrote")
    func importCompensatesOnlyItsOwnFiles() async throws {
        let harness = try AttachmentHarness()
        defer { harness.remove() }
        let owner = try await license(harness.repository)
        let local = try #require(try await harness.repository.addAttachment(
            AttachmentFixtures.file(named: "Local.lic"), to: owner.id).attachments.first)
        let stored = try #require(try await harness.repository.fetchAll().first)

        let failing = SwiftDataLicenseRepository(
            modelContainer: harness.container,
            serials: harness.serials,
            attachments: harness.files,
            now: { self.t },
            beforeSave: { throw PersistFailure() }
        )
        let firstNew = UUID()
        let secondNew = UUID()

        await #expect(throws: PersistFailure()) {
            try await failing.importLicense(
                stored, serial: nil,
                attachments: [
                    AttachmentFixtures.imported(id: firstNew, named: "A.lic"),
                    AttachmentFixtures.imported(id: secondNew, named: "B.lic"),
                ],
                policy: .replace)
        }

        // Both files this call wrote are gone, and the local one is untouched.
        #expect(!harness.fileExists(firstNew))
        #expect(!harness.fileExists(secondNew))
        #expect(harness.fileExists(local.id))
        let rows = try ModelContext(harness.container).fetch(FetchDescriptor<AttachmentRecord>())
        #expect(rows.map(\.id) == [local.id])
    }
}
