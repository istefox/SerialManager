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

    /// True once the user typed a confirmation that differs from the password.
    var showsMismatch: Bool { !confirmation.isEmpty && password != confirmation }

    var canExport: Bool { !password.isEmpty && password == confirmation && phase == .entering }

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
        do {
            let preview = try await service.prepareImport(from: fileURL, password: password)
            if preview.conflictingIDs.isEmpty {
                await apply(preview)
            } else {
                phase = .conflicts(preview)
            }
        } catch let error as BackupError {
            backupError = error
            phase = .password
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func apply(_ preview: ImportPreview) async {
        phase = .importing
        do {
            let summary = try await service.applyImport(preview, policy: policy)
            await store.load()
            phase = .done(summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
