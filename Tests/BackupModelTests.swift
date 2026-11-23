import Foundation
import Testing
@testable import SerialManager

@MainActor
struct ExportModelTests {
    private let url = URL(fileURLWithPath: "/tmp/test.smbackup")

    @Test func passwordsMustBeLongEnoughAndEqual() {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        #expect(!model.canExport)
        model.password = "sample-backup-pass"
        #expect(!model.canExport)
        #expect(!model.showsMismatch)
        model.confirmation = "other-backup-pass"
        #expect(model.showsMismatch)
        #expect(!model.canExport)
        model.confirmation = "sample-backup-pass"
        #expect(model.canExport)
    }

    @Test(arguments: [
        ("short-pass", false),
        ("sample-backup-pass", true),
        (String(repeating: " ", count: 12), true),
        // 11 Characters, 12 Unicode scalars: the decomposed accent does not count as a character.
        ("cafe\u{301}-sample", false),
    ])
    func minimumLengthCountsCharacters(password: String, enabled: Bool) {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        model.password = password
        model.confirmation = password
        #expect(model.canExport == enabled)
        #expect(!model.showsMismatch)
    }

    @Test func caseMismatchIsShownAndDisables() {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        model.password = "sample-backup-pass"
        model.confirmation = "sample-backup-paSS"
        #expect(model.showsMismatch)
        #expect(!model.canExport)
    }

    @Test func minimumLengthIsTwelve() {
        #expect(ExportModel.minimumPasswordLength == 12)
    }

    @Test func exportShowsSummary() async {
        let model = ExportModel(service: InMemoryBackupService(repository: .sample()))
        model.password = "sample-backup-pass"
        model.confirmation = "sample-backup-pass"
        await model.export(to: url)
        // The attachment count comes from the fixtures, not a literal, so adding another sample
        // with attachments cannot make this expectation drift (SPEC 0018, R26).
        #expect(model.phase == .done(
            ExportSummary(
                licenseCount: SampleData.entries.count, missingSerialCount: 1,
                attachmentCount: SampleData.licenses.reduce(0) { $0 + $1.attachments.count }),
            url))
    }

    @Test func keychainFailureShowsMessageAndRetryKeepsPassword() async throws {
        let model = ExportModel(service: FailingExportService(error: SerialStoreError.accessDenied))
        model.password = "sample-backup-pass"
        model.confirmation = "sample-backup-pass"
        await model.export(to: url)
        let text = try #require(SerialStoreError.accessDenied.errorDescription)
        #expect(model.phase == .failed(text))
        model.retry()
        #expect(model.phase == .entering)
        #expect(model.password == "sample-backup-pass")
        #expect(model.confirmation == "sample-backup-pass")
        #expect(model.canExport)
    }
}

/// Export always throws the given error; import is never used by these tests.
private struct FailingExportService: BackupService {
    let error: any Error & Sendable

    func export(to url: URL, password: String) async throws -> ExportSummary { throw error }

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        throw UnavailableBackupService.NotAvailable()
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        throw UnavailableBackupService.NotAvailable()
    }

    func cancelImport() {}
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

/// `ImportModel` close and reload rules (docs/plans/0010-encrypted-import-plan.md, T4; SPEC R10, A17).
@MainActor
struct ImportModelCloseTests {
    private let url = URL(fileURLWithPath: "/tmp/test.smbackup")

    private func makeModel(
        _ service: RecordingBackupService, repository: InMemoryLicenseRepository
    ) async -> (ImportModel, LicenseStore) {
        let store = LicenseStore(repository: repository)
        await store.load()
        let model = ImportModel(fileURL: url, service: service, store: store)
        model.password = "sample-pass"
        return (model, store)
    }

    @Test func failedApplyReloadsTheListAndShowsTheError() async throws {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository, failsApply: true)
        let (model, store) = await makeModel(service, repository: repository)
        #expect(store.licenses.isEmpty)

        await model.unlock()

        #expect(store.licenses.map(\.productName) == [RecordingBackupService.writtenName])
        #expect(model.phase == .failed(StoppedImport().localizedDescription))
    }

    @Test func closeAtPasswordCancelsOnce() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository)
        let (model, _) = await makeModel(service, repository: repository)

        await model.close()

        #expect(await service.cancelCount == 1)
    }

    @Test func closeAtConflictsCancelsOnce() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository, conflicts: [UUID()])
        let (model, _) = await makeModel(service, repository: repository)
        await model.unlock()
        guard case .conflicts = model.phase else {
            Issue.record("expected conflicts phase")
            return
        }

        await model.close()

        #expect(await service.cancelCount == 1)
        #expect(await service.applyCount == 0)
    }

    @Test func closeTwiceCancelsOnce() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository)
        let (model, _) = await makeModel(service, repository: repository)

        await model.close()
        await model.close()

        #expect(await service.cancelCount == 1)
    }

    /// Closed while `prepareImport` runs: one cancel at close, one more when it returns (plan 2.8),
    /// no apply, and the phase stays where it was, whatever the prepare returns.
    @Test(arguments: [
        CheckingOutcome.noConflicts, CheckingOutcome.conflicts, CheckingOutcome.wrongPassword,
    ])
    func closeWhileCheckingCancelsAndWritesNothing(outcome: CheckingOutcome) async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(
            repository: repository,
            conflicts: outcome == .conflicts ? [UUID()] : [],
            prepareError: outcome == .wrongPassword ? .wrongPassword : nil,
            holdsPrepare: true)
        let (model, store) = await makeModel(service, repository: repository)
        var entered = service.prepareEntered.makeAsyncIterator()

        let unlock = Task { await model.unlock() }
        await entered.next()
        #expect(model.phase == .checking)

        await model.close()
        #expect(await service.cancelCount == 1)

        await service.releasePrepare()
        await unlock.value

        #expect(await service.cancelCount == 2)
        #expect(await service.applyCount == 0)
        #expect(model.phase == .checking)
        #expect(model.backupError == nil)
        #expect(store.licenses.isEmpty)
    }

    @Test func closeAfterDoneCancelsNothing() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository)
        let (model, _) = await makeModel(service, repository: repository)
        await model.unlock()
        #expect(model.phase == .done(ImportSummary(imported: 1, replaced: 0, skipped: 0)))

        await model.close()

        #expect(await service.cancelCount == 0)
    }

    @Test func closeAfterFailedApplyCancelsNothing() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository, failsApply: true)
        let (model, _) = await makeModel(service, repository: repository)
        await model.unlock()
        guard case .failed = model.phase else {
            Issue.record("expected failed phase")
            return
        }

        await model.close()

        #expect(await service.cancelCount == 0)
    }

    @Test func forwardPathNeverCancels() async {
        let repository = InMemoryLicenseRepository()
        let service = RecordingBackupService(repository: repository, conflicts: [UUID()])
        let (model, _) = await makeModel(service, repository: repository)

        await model.unlock()
        guard case .conflicts(let preview) = model.phase else {
            Issue.record("expected conflicts phase")
            return
        }
        await model.apply(preview)

        #expect(model.phase == .done(ImportSummary(imported: 0, replaced: 0, skipped: 1)))
        #expect(await service.cancelCount == 0)
        #expect(await service.applyCount == 1)
    }
}

enum CheckingOutcome: Sendable {
    case noConflicts
    case conflicts
    case wrongPassword
}

/// Test-only stop of an apply, standing in for the service's partial-failure error.
struct StoppedImport: LocalizedError {
    var errorDescription: String? { "Sample stop after one license." }
}

/// `BackupService` that records `cancelImport()` and `applyImport` calls, can hold `prepareImport`
/// until released, and can make `applyImport` write one license and then throw.
private actor RecordingBackupService: BackupService {
    static let writtenName = "Sample Written Before Stop"

    private(set) var cancelCount = 0
    private(set) var applyCount = 0
    nonisolated let prepareEntered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    private let repository: InMemoryLicenseRepository
    private let conflicts: Set<UUID>
    private let prepareError: BackupError?
    private let failsApply: Bool
    private var holdsPrepare: Bool
    private var held: CheckedContinuation<Void, Never>?

    init(
        repository: InMemoryLicenseRepository, conflicts: Set<UUID> = [], prepareError: BackupError? = nil,
        failsApply: Bool = false, holdsPrepare: Bool = false
    ) {
        self.repository = repository
        self.conflicts = conflicts
        self.prepareError = prepareError
        self.failsApply = failsApply
        self.holdsPrepare = holdsPrepare
        (prepareEntered, enteredContinuation) = AsyncStream.makeStream()
    }

    func export(to url: URL, password: String) async throws -> ExportSummary {
        ExportSummary(licenseCount: 0, missingSerialCount: 0)
    }

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        enteredContinuation.yield()
        if holdsPrepare {
            await withCheckedContinuation { held = $0 }
        }
        if let prepareError { throw prepareError }
        return ImportPreview(fileURL: url, licenseCount: 1, conflictingIDs: conflicts)
    }

    func releasePrepare() {
        holdsPrepare = false
        held?.resume()
        held = nil
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        applyCount += 1
        if failsApply {
            _ = try await repository.create(LicenseDraft(productName: Self.writtenName, serial: "FAKE-0000-0000-0001"))
            throw StoppedImport()
        }
        let fresh = preview.licenseCount - preview.conflictingIDs.count
        switch policy {
        case .skip: return ImportSummary(imported: fresh, replaced: 0, skipped: preview.conflictingIDs.count)
        case .replace: return ImportSummary(imported: fresh, replaced: preview.conflictingIDs.count, skipped: 0)
        }
    }

    func cancelImport() {
        cancelCount += 1
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
        let unavailable: any BackupService = UnavailableBackupService()
        #expect(!unavailable.isExportAvailable)
        #expect(!unavailable.isImportAvailable)
        let fake: any BackupService = InMemoryBackupService(repository: InMemoryLicenseRepository())
        #expect(fake.isExportAvailable)
        #expect(fake.isImportAvailable)
    }

    @Test func exportFailsInsteadOfClaimingSuccess() async {
        let model = ExportModel(service: UnavailableBackupService())
        model.password = "sample-backup-pass"
        model.confirmation = "sample-backup-pass"
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
