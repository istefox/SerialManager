import Foundation
import Testing
@testable import SerialManager

@MainActor
struct LicenseStoreTests {
    private func makeStore(_ entries: [(LicenseSummary, String?)] = SampleData.entries) async -> LicenseStore {
        let store = LicenseStore(repository: InMemoryLicenseRepository(entries: entries))
        await store.load()
        return store
    }

    @Test func loadSortsByNameIgnoringCase() async {
        let store = await makeStore()
        let names = store.licenses.map(\.productName)
        #expect(store.phase == .loaded)
        #expect(names.first == "Acme Photo Studio")
        #expect(names.last == "zeta Test Utility")
    }

    @Test func emptyRepositoryIsEmptyState() async {
        let store = await makeStore([])
        #expect(store.isEmpty)
    }

    @Test func loadFailureIsReported() async {
        struct Boom: Error {}
        let store = LicenseStore(repository: InMemoryLicenseRepository(failure: Boom()))
        await store.load()
        guard case .failed = store.phase else {
            Issue.record("expected failed phase")
            return
        }
    }

    @Test func searchMatchesNameAndVendorCaseInsensitive() async {
        let store = await makeStore()
        store.searchText = "acme"
        #expect(store.visibleLicenses.map(\.productName) == ["Acme Photo Studio"])
        store.searchText = "NOWHERE"
        #expect(store.visibleLicenses.map(\.productName) == ["Fictional Backup Pro"])
        store.searchText = "no such product"
        #expect(store.visibleLicenses.isEmpty)
        store.searchText = "   "
        #expect(store.visibleLicenses.count == SampleData.entries.count)
    }

    @Test func createTrimsKeepsSortAndSelects() async throws {
        let store = await makeStore()
        var draft = LicenseDraft()
        draft.productName = "  Beta Sample App  "
        draft.serial = "BETA-0000-TEST"
        let saved = try await store.save(draft)
        #expect(saved.productName == "Beta Sample App")
        #expect(store.selection == saved.id)
        #expect(store.licenses.map(\.productName)[1] == "Beta Sample App")
        #expect(await store.serial(for: saved.id) == .present("BETA-0000-TEST"))
    }

    @Test func updateReplacesEntry() async throws {
        let store = await makeStore()
        let original = SampleData.first
        var draft = LicenseDraft(original, serial: "ACME-0000-TEST-0000")
        draft.version = "4.0"
        _ = try await store.save(draft, id: original.id)
        #expect(store.licenses.count == SampleData.entries.count)
        #expect(store.licenses.first { $0.id == original.id }?.version == "4.0")
    }

    @Test func deleteClearsSelection() async throws {
        let store = await makeStore()
        let id = SampleData.first.id
        store.selection = id
        try await store.delete(id: id)
        #expect(store.selection == nil)
        #expect(!store.licenses.contains { $0.id == id })
    }

    @Test func missingSerialIsReported() async {
        let store = await makeStore()
        #expect(await store.serial(for: SampleData.missingSerial.id) == .missing)
    }

    @Test func draftValidation() {
        var draft = LicenseDraft()
        #expect(!draft.hasValidProductName)
        draft.productName = " \n "
        #expect(!draft.hasValidProductName)
        draft.productName = "Acme"
        #expect(draft.hasValidProductName)
    }
}

struct InMemoryBackupServiceTests {
    @Test func wrongPasswordIsRejected() async {
        let service = InMemoryBackupService(repository: .sample())
        await #expect(throws: BackupError.wrongPassword) {
            try await service.prepareImport(from: URL(fileURLWithPath: "/tmp/x.smbackup"), password: "nope")
        }
    }

    @Test func conflictPolicyDrivesSummary() async throws {
        let conflicts: Set<UUID> = [UUID(), UUID()]
        let service = InMemoryBackupService(repository: .sample(), importLicenseCount: 5, importConflicts: conflicts)
        let preview = try await service.prepareImport(
            from: URL(fileURLWithPath: "/tmp/x.smbackup"), password: InMemoryBackupService.samplePassword)
        #expect(try await service.applyImport(preview, policy: .skip) == ImportSummary(imported: 3, replaced: 0, skipped: 2))
        #expect(try await service.applyImport(preview, policy: .replace) == ImportSummary(imported: 3, replaced: 2, skipped: 0))
    }

    @Test func exportCountsMissingSerials() async throws {
        let service = InMemoryBackupService(repository: .sample())
        let summary = try await service.export(to: URL(fileURLWithPath: "/tmp/x.smbackup"), password: "p")
        #expect(summary == ExportSummary(licenseCount: SampleData.entries.count, missingSerialCount: 1))
    }

    // MARK: cancelImport (R17, A15 on the fake)

    private let importURL = URL(fileURLWithPath: "/tmp/x.smbackup")

    @Test func applyAfterCancelFailsAndWritesNothing() async throws {
        let repository = InMemoryLicenseRepository.sample()
        let before = try await repository.fetchAll()
        let service = InMemoryBackupService(repository: repository, importLicenseCount: 2)
        let preview = try await service.prepareImport(from: importURL, password: InMemoryBackupService.samplePassword)

        await service.cancelImport()

        let error = await #expect(throws: (any Error).self) {
            try await service.applyImport(preview, policy: .skip)
        }
        #expect(!(error is BackupError))
        #expect(try await repository.fetchAll() == before)
    }

    @Test func cancelIsIdempotentAndSafeWithNothingPending() async throws {
        let service = InMemoryBackupService(repository: .sample())
        await service.cancelImport()
        _ = try await service.prepareImport(from: importURL, password: InMemoryBackupService.samplePassword)
        await service.cancelImport()
        await service.cancelImport()
    }

    @Test func applyWithoutPrepareFails() async {
        let service = InMemoryBackupService(repository: .sample())
        let preview = ImportPreview(fileURL: importURL, licenseCount: 1, conflictingIDs: [])
        await #expect(throws: (any Error).self) {
            try await service.applyImport(preview, policy: .skip)
        }
    }

    @Test func failedPrepareDropsTheEarlierPendingImport() async throws {
        let service = InMemoryBackupService(repository: .sample())
        let preview = try await service.prepareImport(from: importURL, password: InMemoryBackupService.samplePassword)
        await #expect(throws: BackupError.wrongPassword) {
            try await service.prepareImport(from: importURL, password: "nope")
        }
        await #expect(throws: (any Error).self) {
            try await service.applyImport(preview, policy: .skip)
        }
    }

    @Test func prepareAgainAfterCancelAllowsApply() async throws {
        let service = InMemoryBackupService(repository: .sample(), importLicenseCount: 3)
        _ = try await service.prepareImport(from: importURL, password: InMemoryBackupService.samplePassword)
        await service.cancelImport()
        let preview = try await service.prepareImport(from: importURL, password: InMemoryBackupService.samplePassword)
        #expect(try await service.applyImport(preview, policy: .skip) == ImportSummary(imported: 3, replaced: 0, skipped: 0))
    }

    @Test func unavailableServiceCancelReturns() async {
        let service: any BackupService = UnavailableBackupService()
        await service.cancelImport()
    }
}
