import CryptoKit
import Foundation
import Testing
@testable import SerialManager

/// Real export service (plan 0009, T2): ADR 0002 file layout, payload, failures and isolation.
/// Every test derives at the real 600,000 iterations, in its own temporary directory, on a
/// scripted repository: the real Keychain is never touched.
struct EncryptedBackupServiceTests {
    private typealias F = BackupFixtures

    // MARK: - A1: header, size, summary, payload

    @Test func headerMatchesADRLayout() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: F.password)

        let bytes = [UInt8](try Data(contentsOf: url))
        let fixed: [UInt8] = [
            0x53, 0x4D, 0x42, 0x41, 0x43, 0x4B, 0x55, 0x50, // SMBACKUP
            0x00, 0x01,                                     // version 1
            0x01,                                           // PBKDF2-HMAC-SHA256
            0x00, 0x09, 0x27, 0xC0,                         // 600,000
            0x10,                                           // salt length 16
        ]
        #expect(Array(bytes[0..<16]) == fixed)
        #expect(Data(bytes[16..<32]) == F.salt)
        #expect(bytes[32] == 0x01) // AES-256-GCM
        #expect(Data(bytes[33..<45]) == F.nonceBytes)
        let length = bytes[45..<49].reduce(0) { ($0 << 8) | Int($1) }
        #expect(bytes.count == 33 + 16 + length + 16)

        let contents = try BackupFileReader.parse(Data(bytes))
        #expect(contents.header.count == 49)
        #expect(contents.ciphertextLength == UInt32(length))
    }

    @Test func roundTripReturnsTheSameData() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let summary = try await F.service().export(to: url, password: F.password)

        #expect(summary == ExportSummary(licenseCount: 2, missingSerialCount: 1))
        let payload = try BackupFileReader.payload(try Data(contentsOf: url), password: F.password)
        #expect(payload.exportedAt == F.exportedAt)
        #expect(payload.licenses == [
            BackupPayload.Entry(F.editor, serial: F.editorSerial),
            BackupPayload.Entry(F.viewer, serial: nil),
        ])
    }

    @Test func rawJSONCarriesEveryFieldAndExplicitNulls() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: F.password)

        let plaintext = try BackupFileReader.decrypt(try Data(contentsOf: url), password: F.password).plaintext
        let root = try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        #expect(Set(root.keys) == ["exportedAt", "licenses"])
        #expect(root["exportedAt"] as? String == "2026-01-01T10:00:00.750Z")
        let licenses = try #require(root["licenses"] as? [[String: Any]])
        try #require(licenses.count == 2)

        let keys: Set<String> = [
            "id", "productName", "vendor", "registeredName", "registeredEmail", "purchaseDate",
            "version", "notes", "createdAt", "updatedAt", "serial",
        ]
        let editor = licenses[0]
        #expect(Set(editor.keys) == keys)
        #expect(editor["id"] as? String == "00000000-0000-4000-8000-000000000001")
        #expect(editor["productName"] as? String == "Sample Editor")
        #expect(editor["vendor"] as? String == "Example Software")
        #expect(editor["registeredName"] as? String == "")
        #expect(editor["registeredEmail"] as? String == "user@example.com")
        #expect(editor["purchaseDate"] is NSNull)
        #expect(editor["version"] as? String == "1.0")
        #expect(editor["notes"] as? String == "")
        #expect(editor["createdAt"] as? String == "2026-01-01T09:00:00.250Z")
        #expect(editor["updatedAt"] as? String == "2026-01-01T09:00:00.500Z")
        #expect(editor["serial"] as? String == "FAKE-0000-0000-0000")

        let viewer = licenses[1]
        #expect(Set(viewer.keys) == keys)
        #expect(viewer["productName"] as? String == "Sample Viewer")
        #expect(viewer["purchaseDate"] as? String == "2026-01-01T00:00:00.000Z")
        #expect(viewer["createdAt"] as? String == "2026-01-01T09:01:00.125Z")
        #expect(viewer["serial"] is NSNull)
    }

    // MARK: - A3: NFC

    @Test func decomposedPasswordOpensWithPrecomposedForm() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: "cafe\u{301}-sample-pw")

        let payload = try BackupFileReader.payload(try Data(contentsOf: url), password: "caf\u{E9}-sample-pw")
        #expect(payload.licenses.count == 2)
    }

    @Test func wrongPasswordDoesNotOpen() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: F.password)

        #expect(throws: (any Error).self) {
            try BackupFileReader.decrypt(try Data(contentsOf: url), password: "sample-backup-paSS")
        }
    }

    // MARK: - A4: empty serial

    @Test func emptySerialIsExportedAsNullAndCounted() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let repository = ScriptedLicenseRepository(
            licenses: [F.editor, F.viewer],
            serials: [F.editor.id: .value(""), F.viewer.id: .value("FAKE-1111-1111-1111")]
        )
        let summary = try await F.service(repository: repository).export(to: url, password: F.password)

        #expect(summary == ExportSummary(licenseCount: 2, missingSerialCount: 1))
        let plaintext = try BackupFileReader.decrypt(try Data(contentsOf: url), password: F.password).plaintext
        #expect(!plaintext.contains(bytes: Data(#""serial":"""#.utf8)))
        let root = try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        let licenses = try #require(root["licenses"] as? [[String: Any]])
        #expect(licenses.first?["serial"] is NSNull)
        #expect(licenses.last?["serial"] as? String == "FAKE-1111-1111-1111")
    }

    // MARK: - A5: Keychain failure

    @Test func keychainFailureAbortsAndCreatesNoFile() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let repository = ScriptedLicenseRepository(
            licenses: [F.editor, F.viewer],
            serials: [F.editor.id: .value(F.editorSerial), F.viewer.id: .failure(SerialStoreError.accessDenied)]
        )

        await #expect(throws: SerialStoreError.accessDenied) {
            try await F.service(repository: repository).export(to: url, password: F.password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(await repository.serialReads == [F.editor.id, F.viewer.id])
    }

    @Test func keychainFailureKeepsExistingFileBytes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let original = Data("previous backup bytes".utf8)
        try original.write(to: url)
        let repository = ScriptedLicenseRepository(
            licenses: [F.editor, F.viewer],
            serials: [F.editor.id: .value(F.editorSerial), F.viewer.id: .failure(SerialStoreError.accessDenied)]
        )

        await #expect(throws: SerialStoreError.accessDenied) {
            try await F.service(repository: repository).export(to: url, password: F.password)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func repositoryFailureIsRethrownUnchanged() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let repository = ScriptedLicenseRepository(fetchFailure: LicenseRepositoryError.libraryUnavailable)

        await #expect(throws: LicenseRepositoryError.libraryUnavailable) {
            try await F.service(repository: repository).export(to: url, password: F.password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: - A6: size cap

    @Test func oversizedExportFailsBeforeDerivingAKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let saltCalls = Recorder<Int>()
        let service = F.service(
            saltSource: { count in saltCalls.append(count); return F.salt },
            maxFileSize: 200
        )

        await #expect(throws: BackupExportError.fileTooLarge) {
            try await service.export(to: url, password: F.password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(saltCalls.values.isEmpty)
    }

    @Test func oversizedExportKeepsExistingFileBytes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let original = Data("previous backup bytes".utf8)
        try original.write(to: url)

        await #expect(throws: BackupExportError.fileTooLarge) {
            try await F.service(maxFileSize: 200).export(to: url, password: F.password)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    // MARK: - A7: fresh randomness, injected sources

    @Test func twoExportsWithDefaultSourcesDiffer() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let service = EncryptedBackupService(repository: F.repository())
        let first = dir.file("first.smbackup")
        let second = dir.file("second.smbackup")
        _ = try await service.export(to: first, password: F.password)
        _ = try await service.export(to: second, password: F.password)

        let a = try BackupFileReader.parse(try Data(contentsOf: first))
        let b = try BackupFileReader.parse(try Data(contentsOf: second))
        #expect(a.salt != b.salt)
        #expect(a.nonce != b.nonce)
        #expect(a.ciphertext != b.ciphertext)
        #expect(try BackupFileReader.payload(try Data(contentsOf: second), password: F.password).licenses.count == 2)
    }

    @Test func injectedSourcesAreWrittenToTheFile() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: F.password)

        let (contents, plaintext) = try BackupFileReader.decrypt(try Data(contentsOf: url), password: F.password)
        #expect(contents.salt == F.salt)
        #expect(contents.nonce == F.nonceBytes)
        let payload = try BackupPayload.makeDecoder().decode(BackupPayload.self, from: plaintext)
        #expect(payload.exportedAt == F.exportedAt)
    }

    @Test func saltSourceOfTheWrongLengthFails() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()

        await #expect(throws: BackupExportError.encryptionFailed) {
            try await F.service(saltSource: { _ in Data(repeating: 0, count: 8) }).export(to: url, password: F.password)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: - A8: nothing in clear

    @Test func fileHoldsNoClearText() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        _ = try await F.service().export(to: url, password: F.password)

        let file = try Data(contentsOf: url)
        for needle in [
            "FAKE-0000-0000-0000", "Sample Editor", "Sample Viewer", "user@example.com",
            "2026-01-01T10:00:00.750Z", "licenses", F.password,
        ] {
            #expect(!file.contains(bytes: Data(needle.utf8)), "found \(needle) in clear")
        }
    }

    // MARK: - A10: empty library

    @Test func emptyLibraryExportsAnEmptyList() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let summary = try await F.service(repository: ScriptedLicenseRepository()).export(to: url, password: F.password)

        #expect(summary == ExportSummary(licenseCount: 0, missingSerialCount: 0))
        let plaintext = try BackupFileReader.decrypt(try Data(contentsOf: url), password: F.password).plaintext
        let root = try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        let licenses = try #require(root["licenses"] as? [Any])
        #expect(licenses.isEmpty)
    }

    // MARK: - R9: write errors

    @Test func writeErrorInReadOnlyFolderKeepsExistingBytes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let folder = dir.url.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appending(path: "Licenses.smbackup", directoryHint: .notDirectory)
        let original = Data("previous backup bytes".utf8)
        try original.write(to: url)
        let path = folder.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

        let error = await #expect(throws: CocoaError.self) {
            try await F.service().export(to: url, password: F.password)
        }
        #expect(error?.code == .fileWriteNoPermission)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func missingParentFolderCreatesNothing() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let folder = dir.url.appending(path: "missing", directoryHint: .isDirectory)
        let url = folder.appending(path: "Licenses.smbackup", directoryHint: .notDirectory)

        let error = await #expect(throws: CocoaError.self) {
            try await F.service().export(to: url, password: F.password)
        }
        #expect(error?.code == .fileNoSuchFile)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    // MARK: - R11: off the main actor

    /// Called from the main actor: the salt, the key derivation and the encryption must each still
    /// run off the main thread. The probes wrap the real derivation and sealing, so a stage moved
    /// onto the main actor shows up as `true` here.
    @MainActor
    @Test func cpuBoundStagesRunOffTheMainThread() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.file()
        let saltOnMain = Recorder<Bool>()
        let stages = Recorder<BackupStage>()
        let stagesOnMain = Recorder<Bool>()
        let service = F.service(
            saltSource: { _ in saltOnMain.append(Thread.isMainThread); return F.salt },
            stageProbe: { stage in stages.append(stage); stagesOnMain.append(Thread.isMainThread) }
        )

        _ = try await service.export(to: url, password: F.password)
        #expect(saltOnMain.values == [false])
        #expect(stages.values == [.keyDerivation, .encryption])
        #expect(stagesOnMain.values == [false, false])
        #expect(try BackupFileReader.payload(try Data(contentsOf: url), password: F.password).licenses.count == 2)
    }

    // MARK: - Availability and import

    @Test func exportAndImportAreAvailable() {
        let service = EncryptedBackupService(repository: ScriptedLicenseRepository())
        #expect(service.isExportAvailable)
        #expect(service.isImportAvailable)
    }

    @Test func importOfAMissingFileRethrowsTheOpenErrorAndKeepsNothing() async throws {
        let service = EncryptedBackupService(repository: ScriptedLicenseRepository())
        let url = URL(filePath: "/nonexistent/Licenses.smbackup")
        let error = await #expect(throws: (any Error).self) {
            try await service.prepareImport(from: url, password: F.password)
        }
        #expect(!(error is BackupError))
        let preview = ImportPreview(fileURL: url, licenseCount: 0, conflictingIDs: [])
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .skip)
        }
    }
}
