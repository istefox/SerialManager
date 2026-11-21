import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Import through the real service (SPEC 0010 A1 to A16, R4 to R17; plan 0010, 2.7 and T3).
///
/// Real `EncryptedBackupService` and `SwiftDataLicenseRepository` on an in-memory store with
/// `ScriptedSerialStore`: no test touches the real Keychain. Key derivation runs at the real
/// 600,000 iterations. Sample values are fake.
@MainActor
struct EncryptedBackupImportTests {
    private typealias F = BackupFixtures
    private typealias J = BackupPayloadJSON

    private let editorID = BackupFixtures.editor.id
    private let viewerID = BackupFixtures.viewer.id
    private let localSerial = "FAKE-LOCAL-0001"
    private let fileSerial = "FAKE-FILE-0001"

    /// Licenses sorted by id with dates rounded to the millisecond, and the serial store items.
    private struct LibraryState: Equatable {
        let licenses: [LicenseSummary]
        let items: [UUID: String]
    }

    // MARK: Helpers

    private func makeLibrary(_ serials: ScriptedSerialStore) throws -> SwiftDataLicenseRepository {
        let container = try ModelContainer(
            for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataLicenseRepository(modelContainer: container, serials: serials)
    }

    private static func ms(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private static func ms(_ s: LicenseSummary) -> LicenseSummary {
        LicenseSummary(
            id: s.id, productName: s.productName, vendor: s.vendor, registeredEmail: s.registeredEmail,
            purchaseDate: s.purchaseDate.map(ms), version: s.version, notes: s.notes,
            createdAt: ms(s.createdAt), updatedAt: ms(s.updatedAt))
    }

    private func state(_ repository: some LicenseRepository, _ serials: ScriptedSerialStore) async throws -> LibraryState {
        LibraryState(
            licenses: try await repository.fetchAll().map(Self.ms).sorted { $0.id.uuidString < $1.id.uuidString },
            items: await serials.items)
    }

    /// True when the serial store saw no save and no delete.
    private func wroteNoSerial(_ serials: ScriptedSerialStore) async -> Bool {
        let saves = await serials.calls(.save)
        let deletes = await serials.calls(.delete)
        return saves.isEmpty && deletes.isEmpty
    }

    /// Stores `license` with `serial` through the import path, then clears the serial store log.
    private func seed(
        _ repository: SwiftDataLicenseRepository, _ serials: ScriptedSerialStore,
        _ license: LicenseSummary, serial: String?
    ) async throws {
        _ = try await repository.importLicense(license, serial: serial, policy: .replace)
        await serials.clearLog()
    }

    private func fixtureFile(in directory: TemporaryDirectory) throws -> URL {
        let url = directory.file()
        try BackupImportFixture.data.write(to: url)
        return url
    }

    private func sealedFile(
        _ entries: [[String: Any]], in directory: TemporaryDirectory, name: String = "Licenses.smbackup"
    ) throws -> URL {
        let url = directory.file(name)
        let plaintext = try J.payload(entries: entries)
        try BackupFileBuilder().sealed(plaintext, password: F.password).write(to: url)
        return url
    }

    private func entry(_ id: UUID, name: String, serial: Any) -> [String: Any] {
        var entry = J.entry(id: id.uuidString, name: name)
        entry["serial"] = serial
        return entry
    }

    private func numberedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!
    }

    /// License X of A8 as the library holds it.
    private var localX: LicenseSummary {
        LicenseSummary(
            id: editorID, productName: "Local Editor", vendor: "Local Vendor",
            registeredEmail: "local@example.com", purchaseDate: nil, version: "0.9", notes: "Local notes",
            createdAt: Date(timeIntervalSince1970: 1_767_258_000),
            updatedAt: Date(timeIntervalSince1970: 1_767_258_000))
    }

    // MARK: A1, A2, A12

    @Test func fixtureIntoAnEmptyLibrary() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)

        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        #expect(preview.licenseCount == 2)
        #expect(preview.conflictingIDs.isEmpty)
        #expect(await wroteNoSerial(serials))

        let summary = try await service.applyImport(preview, policy: .skip)
        #expect(summary == ImportSummary(imported: 2, replaced: 0, skipped: 0))
        #expect(try await state(repository, serials) == LibraryState(
            licenses: [F.editor, F.viewer].map(Self.ms), items: [editorID: F.editorSerial]))
        #expect(await serials.calls(.save).map(\.id) == [editorID])
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test func exportThenImportIntoANewLibraryRoundTrips() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let sourceSerials = ScriptedSerialStore()
        let source = SwiftDataLicenseRepository(
            modelContainer: try ModelContainer(
                for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)),
            serials: sourceSerials,
            now: { Date(timeIntervalSince1970: 1_767_258_000.250) })
        _ = try await source.create(LicenseDraft(productName: "Sample One", vendor: "Example", serial: "FAKE-0001"))
        _ = try await source.create(LicenseDraft(
            productName: "Sample Two", registeredEmail: "two@example.com",
            purchaseDate: Date(timeIntervalSince1970: 1_767_225_600), version: "2", notes: "Fake", serial: ""))
        _ = try await source.create(LicenseDraft(productName: "Sample Three", serial: "FAKE-0003"))
        let url = directory.file()
        _ = try await EncryptedBackupService(repository: source).export(to: url, password: F.password)

        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = EncryptedBackupService(repository: repository)
        let preview = try await service.prepareImport(from: url, password: F.password)
        let summary = try await service.applyImport(preview, policy: .skip)

        #expect(summary == ImportSummary(imported: 3, replaced: 0, skipped: 0))
        let expected = try await state(source, sourceSerials)
        #expect(expected.licenses.count == 3)
        #expect(expected.items.count == 2)
        #expect(try await state(repository, serials) == expected)
    }

    @Test func emptyFileImportsNothing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)

        let preview = try await service.prepareImport(from: try sealedFile([], in: directory), password: F.password)
        #expect(preview == ImportPreview(fileURL: directory.file(), licenseCount: 0, conflictingIDs: []))
        #expect(try await service.applyImport(preview, policy: .replace) == ImportSummary(imported: 0, replaced: 0, skipped: 0))
        #expect(try await repository.fetchAll().isEmpty)
    }

    // MARK: A3, A4, A5: a failed prepare writes nothing (R4)

    enum Rejected: String, CaseIterable, CustomTestStringConvertible {
        case wrongPassword, corrupted, newerVersion

        var testDescription: String { rawValue }

        var expected: BackupError {
            switch self {
            case .wrongPassword: .wrongPassword
            case .corrupted: .corruptedFile
            case .newerVersion: .unsupportedVersion
            }
        }
    }

    @Test(arguments: Rejected.allCases)
    func rejectedFileChangesNothing(_ rejected: Rejected) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: localSerial)
        let before = try await state(repository, serials)
        let service = F.service(repository: repository)

        let url = directory.file()
        var password = F.password
        switch rejected {
        case .wrongPassword:
            try BackupImportFixture.data.write(to: url)
            password = "sample-backup-paSS"
        case .corrupted:
            var builder = BackupFileBuilder()
            builder.kdfID = 0x02
            try builder.unsealed().write(to: url)
        case .newerVersion:
            var builder = BackupFileBuilder()
            builder.version = 2
            try builder.unsealed().write(to: url)
        }

        await #expect(throws: rejected.expected) {
            try await service.prepareImport(from: url, password: password)
        }
        #expect(try await state(repository, serials) == before)
        #expect(await wroteNoSerial(serials))
        let preview = ImportPreview(fileURL: url, licenseCount: 0, conflictingIDs: [])
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
    }

    // MARK: A8, A9, A10: conflicts

    @Test func skipKeepsTheLocalLicenseAndItsSerial() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: localSerial)
        let service = F.service(repository: repository)
        let url = try sealedFile([
            entry(editorID, name: "Sample Editor", serial: fileSerial),
            entry(viewerID, name: "Sample Viewer", serial: NSNull()),
        ], in: directory)

        let preview = try await service.prepareImport(from: url, password: F.password)
        #expect(preview.conflictingIDs == [editorID])

        let summary = try await service.applyImport(preview, policy: .skip)
        #expect(summary == ImportSummary(imported: 1, replaced: 0, skipped: 1))
        let after = try await state(repository, serials)
        #expect(after.licenses.first { $0.id == editorID } == Self.ms(localX))
        #expect(after.items == [editorID: localSerial])
        #expect(after.licenses.map(\.id).contains(viewerID))
    }

    @Test func replaceTakesTheFileFieldsDatesAndSerial() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: localSerial)
        let service = F.service(repository: repository)
        let url = try sealedFile([entry(editorID, name: "Sample Editor", serial: fileSerial)], in: directory)

        let preview = try await service.prepareImport(from: url, password: F.password)
        let summary = try await service.applyImport(preview, policy: .replace)

        #expect(summary == ImportSummary(imported: 0, replaced: 1, skipped: 0))
        #expect(try await state(repository, serials) == LibraryState(
            licenses: [Self.ms(F.editor)], items: [editorID: fileSerial]))
        #expect(await serials.calls(.delete).isEmpty)
    }

    @Test(arguments: ["null", "empty"])
    func replaceWithoutAFileSerialKeepsTheLocalOne(_ form: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: localSerial)
        let service = F.service(repository: repository)
        let serial: Any = form == "null" ? NSNull() : ""
        let url = try sealedFile([entry(editorID, name: "Sample Editor", serial: serial)], in: directory)

        let preview = try await service.prepareImport(from: url, password: F.password)
        let summary = try await service.applyImport(preview, policy: .replace)

        #expect(summary == ImportSummary(imported: 0, replaced: 1, skipped: 0))
        #expect(try await state(repository, serials) == LibraryState(
            licenses: [Self.ms(F.editor)], items: [editorID: localSerial]))
        #expect(await wroteNoSerial(serials))
    }

    @Test func emptyFileSerialCreatesTheLicenseWithoutAnItem() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let url = try sealedFile([entry(editorID, name: "Sample Editor", serial: "")], in: directory)

        let preview = try await service.prepareImport(from: url, password: F.password)
        let summary = try await service.applyImport(preview, policy: .skip)

        #expect(summary == ImportSummary(imported: 1, replaced: 0, skipped: 0))
        #expect(try await state(repository, serials) == LibraryState(licenses: [Self.ms(F.editor)], items: [:]))
        #expect(await wroteNoSerial(serials))
    }

    // MARK: R9: conflicts are decided at apply time

    @Test func conflictAddedAfterThePreviewIsSkipped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)

        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        #expect(preview.conflictingIDs.isEmpty)
        try await seed(repository, serials, localX, serial: localSerial)

        let summary = try await service.applyImport(preview, policy: .skip)
        #expect(summary == ImportSummary(imported: 1, replaced: 0, skipped: 1))
        #expect(try await state(repository, serials).licenses.first { $0.id == editorID } == Self.ms(localX))
    }

    @Test func conflictRemovedAfterThePreviewIsImported() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: nil)
        let service = F.service(repository: repository)

        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        #expect(preview.conflictingIDs == [editorID])
        try await repository.delete(id: editorID)

        let summary = try await service.applyImport(preview, policy: .skip)
        #expect(summary == ImportSummary(imported: 2, replaced: 0, skipped: 0))
    }

    // MARK: A11: a failed write stops the import (D1)

    @Test func failedSaveStopsTheImportAndKeepsWhatWasWritten() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let ids = (1...5).map(numberedID)
        let url = try sealedFile(
            ids.enumerated().map { entry($1, name: "Sample App \($0 + 1)", serial: "FAKE-0000-0000-000\($0 + 1)") },
            in: directory)
        let preview = try await service.prepareImport(from: url, password: F.password)
        await serials.fail(.save, with: SerialStoreError.accessDenied, after: 2)

        let underlying = SerialStoreError.accessDenied.localizedDescription
        let error = await #expect(throws: BackupImportError.self) {
            try await service.applyImport(preview, policy: .skip)
        }
        #expect(error == .interrupted(imported: 2, replaced: 0, underlyingMessage: underlying))
        let message = try #require(error?.errorDescription)
        #expect(!message.contains("FAKE-"))
        #expect(!message.contains("Sample App"))

        let after = try await state(repository, serials)
        #expect(after.licenses.map(\.id) == Array(ids.prefix(2)))
        #expect(after.items == [ids[0]: "FAKE-0000-0000-0001", ids[1]: "FAKE-0000-0000-0002"])
        #expect(await serials.calls(.delete).isEmpty)

        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .skip)
        }
        let again = try await service.prepareImport(from: url, password: F.password)
        #expect(again.conflictingIDs == Set(ids.prefix(2)))
    }

    @Test func failedSaveAfterAReplaceCountsBothKinds() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let ids = (1...3).map(numberedID)
        try await seed(repository, serials, LicenseSummary(
            id: ids[0], productName: "Local App", vendor: "", registeredEmail: "", purchaseDate: nil,
            version: "", notes: "", createdAt: Date(timeIntervalSince1970: 1_767_258_000),
            updatedAt: Date(timeIntervalSince1970: 1_767_258_000)), serial: nil)
        let service = F.service(repository: repository)
        let url = try sealedFile(
            ids.enumerated().map { entry($1, name: "Sample App \($0 + 1)", serial: "FAKE-0000-0000-000\($0 + 1)") },
            in: directory)
        let preview = try await service.prepareImport(from: url, password: F.password)
        await serials.fail(.save, with: SerialStoreError.accessDenied, after: 2)

        await #expect(throws: BackupImportError.interrupted(
            imported: 1, replaced: 1, underlyingMessage: SerialStoreError.accessDenied.localizedDescription)
        ) {
            try await service.applyImport(preview, policy: .replace)
        }
        let after = try await state(repository, serials)
        #expect(after.licenses.map(\.id) == Array(ids.prefix(2)))
        #expect(after.licenses.first?.productName == "Sample App 1")
    }

    // MARK: A13, D5: no pending payload

    @Test func applyWithoutPrepareWritesNothing() async throws {
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let preview = ImportPreview(fileURL: URL(filePath: "/tmp/Licenses.smbackup"), licenseCount: 2, conflictingIDs: [])

        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await repository.fetchAll().isEmpty)
        #expect(await serials.log.isEmpty)
    }

    @Test func secondApplyWithTheSamePreviewWritesNothing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        _ = try await service.applyImport(preview, policy: .replace)
        let before = try await state(repository, serials)
        await serials.clearLog()

        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await state(repository, serials) == before)
        #expect(await serials.log.isEmpty)
    }

    @Test func previewOfAnotherFileFindsNothingAndDropsThePayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        let other = ImportPreview(
            fileURL: directory.file("Other.smbackup"), licenseCount: preview.licenseCount,
            conflictingIDs: preview.conflictingIDs)

        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(other, policy: .replace)
        }
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await repository.fetchAll().isEmpty)
        #expect(await serials.log.isEmpty)
    }

    @Test func failedPrepareDropsTheEarlierPayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)
        let url = try fixtureFile(in: directory)
        let preview = try await service.prepareImport(from: url, password: F.password)

        await #expect(throws: BackupError.wrongPassword) {
            try await service.prepareImport(from: url, password: "sample-backup-paSS")
        }
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await repository.fetchAll().isEmpty)
    }

    // MARK: R12: off the main thread

    @Test func keyDerivationRunsOffTheMainThread() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let onMain = Recorder<Bool>()
        let service = F.service(
            repository: try makeLibrary(ScriptedSerialStore()),
            stageProbe: { if $0 == .keyDerivation { onMain.append(Thread.isMainThread) } })

        _ = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)
        #expect(onMain.values == [false])
    }

    // MARK: A15, A16, R17: cancel

    @Test func cancelAfterPrepareDropsThePayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        try await seed(repository, serials, localX, serial: localSerial)
        let before = try await state(repository, serials)
        let service = F.service(repository: repository)
        let preview = try await service.prepareImport(from: try fixtureFile(in: directory), password: F.password)

        await service.cancelImport()
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await state(repository, serials) == before)
        #expect(await wroteNoSerial(serials))
    }

    @Test func cancelTwiceOrWithNothingPreparedDoesNothing() async throws {
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let service = F.service(repository: repository)

        await service.cancelImport()
        await service.cancelImport()
        #expect(try await repository.fetchAll().isEmpty)
        #expect(await serials.log.isEmpty)
    }

    @Test func cancelDuringTheKeyDerivationLeavesNoPayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let gate = DerivationGate()
        let service = F.service(
            repository: repository, stageProbe: { if $0 == .keyDerivation { gate.hold() } })
        let url = try fixtureFile(in: directory)

        let prepare = Task { try await service.prepareImport(from: url, password: F.password) }
        #expect(await gate.waitForCalls(1))
        await service.cancelImport()
        gate.open()
        let preview = try await prepare.value

        #expect(!gate.didTimeOut)
        #expect(preview.licenseCount == 2)
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(preview, policy: .replace)
        }
        #expect(try await repository.fetchAll().isEmpty)
        #expect(await wroteNoSerial(serials))
    }

    @Test func newerPrepareOfAnotherFileWinsOverAnEarlierOneStillRunning() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let gate = DerivationGate()
        let service = F.service(
            repository: repository, stageProbe: { if $0 == .keyDerivation { gate.hold() } })
        let first = try sealedFile([entry(editorID, name: "Sample Editor", serial: NSNull())], in: directory, name: "A.smbackup")
        let second = try fixtureFile(in: directory)

        let earlier = Task { try await service.prepareImport(from: first, password: F.password) }
        #expect(await gate.waitForCalls(1))
        _ = try await service.prepareImport(from: second, password: F.password)
        gate.open()
        let earlierPreview = try await earlier.value

        #expect(!gate.didTimeOut)
        await #expect(throws: BackupImportError.noPendingImport) {
            try await service.applyImport(earlierPreview, policy: .replace)
        }
        #expect(try await repository.fetchAll().isEmpty)
    }

    @Test func newerPrepareOfTheSameFileKeepsTheNewerPayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let serials = ScriptedSerialStore()
        let repository = try makeLibrary(serials)
        let gate = DerivationGate()
        let service = F.service(
            repository: repository, stageProbe: { if $0 == .keyDerivation { gate.hold() } })
        let url = try sealedFile([entry(editorID, name: "Sample Editor", serial: NSNull())], in: directory)

        let earlier = Task { try await service.prepareImport(from: url, password: F.password) }
        #expect(await gate.waitForCalls(1))
        try BackupImportFixture.data.write(to: url)
        let newer = try await service.prepareImport(from: url, password: F.password)
        gate.open()
        let earlierPreview = try await earlier.value

        #expect(!gate.didTimeOut)
        #expect(earlierPreview.licenseCount == 1)
        #expect(newer.licenseCount == 2)
        let summary = try await service.applyImport(newer, policy: .replace)
        #expect(summary == ImportSummary(imported: 2, replaced: 0, skipped: 0))
        #expect(try await state(repository, serials).licenses == [F.editor, F.viewer].map(Self.ms))
    }
}
