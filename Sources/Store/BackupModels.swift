import Foundation
import Observation

/// State of the export sheet.
@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        case entering
        case exporting
        case done(ExportSummary, URL)
        case failed(String)
    }

    var password = ""
    var confirmation = ""
    private(set) var phase: Phase

    @ObservationIgnored private let service: any BackupService

    init(service: any BackupService, phase: Phase = .entering) {
        self.service = service
        self.phase = phase
    }

    /// Shortest accepted password, counted in `Character`s with no trimming (ADR 0002 section 8).
    /// The hint in `ExportView` repeats this number in a fixed catalog string:
    /// "Use at least 12 characters." Change the two together.
    static let minimumPasswordLength = 12

    /// True once the user typed a confirmation that differs from the password.
    var showsMismatch: Bool { !confirmation.isEmpty && password != confirmation }

    var canExport: Bool {
        password.count >= Self.minimumPasswordLength && password == confirmation && phase == .entering
    }

    func export(to url: URL) async {
        guard canExport else { return }
        phase = .exporting
        do {
            let summary = try await service.export(to: url, password: password)
            phase = .done(summary, url)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() { phase = .entering }
}

/// State of the import sheet, opened after a backup file was chosen.
@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case password
        case checking
        case conflicts(ImportPreview)
        case importing
        case done(ImportSummary)
        case failed(String)
    }

    let fileURL: URL
    var password = ""
    var policy: ConflictPolicy = .skip
    /// Shown inline under the password; the password is kept for a retry.
    private(set) var backupError: BackupError?
    private(set) var phase: Phase

    @ObservationIgnored private let service: any BackupService
    @ObservationIgnored private let store: LicenseStore
    /// Set by `close()`: the sheet is gone, so a `prepareImport` still running must not move on (R17).
    @ObservationIgnored private var isClosed = false
    /// Set by `apply` before its first await: from then on closing the sheet cancels nothing (R17).
    @ObservationIgnored private var applyStarted = false

    init(
        fileURL: URL, service: any BackupService, store: LicenseStore,
        phase: Phase = .password, backupError: BackupError? = nil
    ) {
        self.fileURL = fileURL
        self.service = service
        self.store = store
        self.phase = phase
        self.backupError = backupError
    }

    var canUnlock: Bool { !password.isEmpty && phase == .password }

    func unlock() async {
        guard canUnlock else { return }
        phase = .checking
        backupError = nil
        let result: Result<ImportPreview, any Error>
        do {
            result = .success(try await service.prepareImport(from: fileURL, password: password))
        } catch {
            result = .failure(error)
        }
        // Closed while checking: write nothing and drop what this prepare may have kept. `close()`
        // already cancelled, but the service may have run that cancel before this prepare
        // (docs/plans/0010-encrypted-import-plan.md, 2.8); `cancelImport()` is idempotent.
        if isClosed {
            await service.cancelImport()
            return
        }
        switch result {
        case .success(let preview):
            if preview.conflictingIDs.isEmpty {
                await apply(preview)
            } else {
                phase = .conflicts(preview)
            }
        case .failure(let error as BackupError):
            backupError = error
            phase = .password
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }

    func apply(_ preview: ImportPreview) async {
        applyStarted = true
        phase = .importing
        do {
            let summary = try await service.applyImport(preview, policy: policy)
            await store.load()
            phase = .done(summary)
        } catch {
            // A partial import keeps what it wrote (D1): reload so the list shows it (R10).
            await store.load()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called once when the sheet goes away, whatever closed it (Cancel, Esc, Done, Close).
    /// Before `apply` started it drops the decrypted payload kept by the service (D5, R17);
    /// after that it cancels nothing. Later calls do nothing.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        guard !applyStarted else { return }
        await service.cancelImport()
    }
}
