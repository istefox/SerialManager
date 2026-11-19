import Foundation
import Testing
@testable import SerialManager

@MainActor
struct ExportModelTests {
    private let url = URL(fileURLWithPath: "/tmp/test.smbackup")

    @Test func passwordsMustBeNonEmptyAndEqual() {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        #expect(!model.canExport)
        model.password = "sample"
        #expect(!model.canExport)
        #expect(!model.showsMismatch)
        model.confirmation = "other"
        #expect(model.showsMismatch)
        #expect(!model.canExport)
        model.confirmation = "sample"
        #expect(model.canExport)
    }

    @Test func exportShowsSummary() async {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        model.password = "sample"
        model.confirmation = "sample"
        await model.export(to: url)
        #expect(model.phase == .done(ExportSummary(licenseCount: SampleData.entries.count, missingSerialCount: 1), url))
    }
}

@MainActor
struct ImportModelTests {
    private let url = URL(fileURLWithPath: "/tmp/test.smbackup")

    private func makeModel(conflicts: Set<UUID> = [], error: BackupError? = nil) async -> ImportModel {
        let repository = InMemoryLicenseRepository.sample()
        let store = LicenseStore(repository: repository)
        await store.load()
        let service = InMemoryBackupService(
            repository: repository, importLicenseCount: 4, importConflicts: conflicts, importError: error)
        return ImportModel(fileURL: url, service: service, store: store)
    }

    @Test func wrongPasswordStaysOnPasswordWithError() async {
        let model = await makeModel()
        model.password = "wrong"
        await model.unlock()
        #expect(model.phase == .password)
        #expect(model.backupError == .wrongPassword)
        #expect(model.password == "wrong")
    }

    @Test func corruptedFileIsReported() async {
        let model = await makeModel(error: .corruptedFile)
        model.password = InMemoryBackupService.samplePassword
        await model.unlock()
        #expect(model.backupError == .corruptedFile)
    }

    @Test func noConflictsImportsDirectly() async {
        let model = await makeModel()
        model.password = InMemoryBackupService.samplePassword
        await model.unlock()
        #expect(model.phase == .done(ImportSummary(imported: 4, replaced: 0, skipped: 0)))
    }

    @Test func conflictsAskThenApplyPolicy() async {
        let model = await makeModel(conflicts: [UUID()])
        model.password = InMemoryBackupService.samplePassword
        await model.unlock()
        guard case .conflicts(let preview) = model.phase else {
            Issue.record("expected conflicts phase")
            return
        }
        #expect(model.policy == .skip)
        model.policy = .replace
        await model.apply(preview)
        #expect(model.phase == .done(ImportSummary(imported: 3, replaced: 1, skipped: 0)))
    }

    @Test func emptyPasswordCannotUnlock() async {
        let model = await makeModel()
        #expect(!model.canUnlock)
    }
}

struct BackupFileNameTests {
    @MainActor @Test func defaultNameUsesDateAndExtension() {
        let name = BackupFilePanels.defaultFileName(on: SampleData.reference)
        #expect(name == "SerialManager Backup 2026-01-01.smbackup")
    }
}

@MainActor
struct UnavailableBackupServiceTests {
    private let url = URL(fileURLWithPath: "/tmp/test.smbackup")

    @Test func reportsItselfUnavailable() {
        #expect(!UnavailableBackupService().isAvailable)
        #expect(InMemoryBackupService(repository: InMemoryLicenseRepository()).isAvailable)
    }

    @Test func exportFailsInsteadOfClaimingSuccess() async {
        let model = ExportModel(service: UnavailableBackupService())
        model.password = "sample"
        model.confirmation = "sample"
        await model.export(to: url)
        guard case .failed = model.phase else {
            Issue.record("Expected a failure, got \(model.phase)")
            return
        }
    }

    @Test func importFailsAndImportsNothing() async {
        let repository = InMemoryLicenseRepository()
        let store = LicenseStore(repository: repository)
        await store.load()
        let model = ImportModel(fileURL: url, service: UnavailableBackupService(), store: store)
        model.password = InMemoryBackupService.samplePassword
        await model.unlock()
        guard case .failed = model.phase else {
            Issue.record("Expected a failure, got \(model.phase)")
            return
        }
        #expect(store.licenses.isEmpty)
    }
}
