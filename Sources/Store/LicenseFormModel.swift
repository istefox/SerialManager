import Foundation
import Observation
import UniformTypeIdentifiers

/// A file picked in the form but not yet written (SPEC 0018, D13 and R16).
///
/// `id` is local to this sheet: the stored attachment's id is assigned by the repository when the
/// file is actually written, on Save.
struct PendingAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let file: AttachmentFile

    init(id: UUID = UUID(), file: AttachmentFile) {
        self.id = id
        self.file = file
    }

    var fileName: String { file.fileName }
    var byteCount: Int { file.byteCount }
}

/// State of the license form sheet, for both New License and Edit License.
@MainActor
@Observable
final class LicenseFormModel {
    /// The license being edited; nil for a new one.
    ///
    /// A `var`, not a snapshot: Save can half-succeed (the fields are written, an attachment
    /// fails) and leave the sheet open, so every call that returns a fresh `LicenseSummary`
    /// assigns it here. Without that, a second Save would create the license twice, and the
    /// attachment lists and the size math would keep reading the state before the first Save.
    private(set) var license: LicenseSummary?
    /// Whether the sheet opened on an existing license. Fixed for the life of the sheet, so the
    /// title and the Delete button do not change under the user when `license` is filled in by a
    /// partially successful Save.
    let isEditing: Bool
    var draft: LicenseDraft
    private(set) var original: LicenseDraft
    var showsNameError = false
    private(set) var isSaving = false
    private(set) var isLoadingSerial: Bool
    /// True when the current serial could not be read: saving an empty serial would erase it.
    private(set) var serialUnreadable = false
    var errorMessage: String?
    /// Which action set `errorMessage`, so the alert can name it (D3).
    private(set) var failedAction: FailedAction = .save

    /// Files picked but not written yet. Nothing reaches the library until Save (D13).
    private(set) var pendingAttachments: [PendingAttachment] = []
    /// Stored attachments the user marked for removal. Applied on Save, not before.
    private(set) var removedAttachmentIDs: Set<UUID> = []
    /// Why the last picked file was refused, shown inline in the Attachments section (R16).
    var attachmentError: String?

    enum FailedAction { case save, delete }

    init(license: LicenseSummary? = nil, draft: LicenseDraft? = nil) {
        self.license = license
        self.isEditing = license != nil
        let start = draft ?? license.map { LicenseDraft($0, serial: nil) } ?? LicenseDraft()
        self.draft = start
        self.original = start
        self.isLoadingSerial = license != nil && draft == nil
    }

    /// Pending attachments count as changes, so Cancel raises the discard confirmation (R17).
    var hasChanges: Bool { draft != original || hasAttachmentChanges }
    var hasAttachmentChanges: Bool { !pendingAttachments.isEmpty || !removedAttachmentIDs.isEmpty }

    /// The stored attachments still shown, in order, with the removed ones taken out.
    var keptAttachments: [AttachmentSummary] {
        (license?.attachments ?? []).filter { !removedAttachmentIDs.contains($0.id) }
    }

    /// Plaintext bytes this license would hold after Save.
    var attachmentBytes: Int {
        keptAttachments.reduce(0) { $0 + $1.byteCount }
            + pendingAttachments.reduce(0) { $0 + $1.byteCount }
    }

    /// Reads `url` and holds it for Save, or sets `attachmentError` and holds nothing.
    ///
    /// The limits of D3 and D4 are checked here, at the moment the file is picked, against what
    /// this sheet would save, not against what is stored now: two 3 MB files picked in one sitting
    /// must be refused together even though neither is over on its own (R16, R17).
    func pickAttachment(at url: URL, in store: LicenseStore) {
        let fileName = url.lastPathComponent
        guard AttachmentRecord.isValidFileName(fileName) else {
            report(String(localized: "\(fileName) isn't a usable file name."))
            return
        }

        // The size is checked from the file system before the bytes are read: a 2 GB file picked
        // by mistake must be refused without pulling it into memory on the main actor.
        guard let declared = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            report(String(localized: "\(fileName) couldn't be read."))
            return
        }
        guard checkLimits(byteCount: declared, fileName: fileName, in: store) else { return }

        // No app-sandbox entitlement today, so these calls are no-ops; they are here so that
        // turning the sandbox on does not silently break reading a picked file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            report(String(localized: "\(fileName) couldn't be read: \(error.localizedDescription)"))
            return
        }
        // Checked again on the bytes actually read: the file may have grown since the stat.
        guard checkLimits(byteCount: data.count, fileName: fileName, in: store) else { return }

        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier
        pendingAttachments.append(
            PendingAttachment(
                file: AttachmentFile(fileName: fileName, contentType: contentType, data: data)))
    }

    /// Checks one candidate against D3 and D4, reporting the refusal. True when it fits.
    private func checkLimits(byteCount: Int, fileName: String, in store: LicenseStore) -> Bool {
        // The library total counts every other license plus what this sheet would leave behind.
        let storedForThisLicense = (license?.attachments ?? []).reduce(0) { $0 + $1.byteCount }
        let elsewhere = store.libraryAttachmentBytes - storedForThisLicense
        do {
            try AttachmentLimits.check(
                byteCount: byteCount,
                fileName: fileName,
                licenseBytes: attachmentBytes,
                libraryBytes: elsewhere + attachmentBytes
            )
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    /// Adds one refusal to the message. A pick of several files keeps every reason, not the last.
    private func report(_ message: String) {
        attachmentError = attachmentError.map { "\($0)\n\(message)" } ?? message
    }

    /// Clears the refusals of the previous pick. The view calls it once per file-importer result,
    /// before `pickAttachment` runs for each chosen file.
    func clearAttachmentError() {
        attachmentError = nil
    }

    /// Drops a picked file that was never written.
    func cancelPendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        attachmentError = nil
    }

    /// Takes in a license that was just written, so a retry after a partial Save reads the state
    /// the library is actually in.
    private func adopt(_ saved: LicenseSummary) {
        license = saved
    }

    /// Marks a stored attachment for removal on Save, or takes the mark back.
    func toggleRemoval(of id: UUID) {
        if removedAttachmentIDs.contains(id) {
            removedAttachmentIDs.remove(id)
        } else {
            removedAttachmentIDs.insert(id)
        }
        attachmentError = nil
    }

    /// Bridges the optional purchase date to a toggle.
    var hasPurchaseDate: Bool {
        get { draft.purchaseDate != nil }
        set { draft.purchaseDate = newValue ? (draft.purchaseDate ?? Date()) : nil }
    }

    /// Loads the current serial of the edited license into the draft.
    func loadSerial(from store: LicenseStore) async {
        guard let license, isLoadingSerial else { return }
        defer { isLoadingSerial = false }
        switch await store.serialWithoutRecording(for: license.id) {
        case .present(let serial):
            // Keep anything the user already typed while the serial was loading.
            if draft.serial.isEmpty { draft.serial = serial }
            original.serial = serial
        case .failed:
            serialUnreadable = true
        case .missing, .loading:
            break
        }
    }

    /// Validates and saves. Returns true when the sheet can close.
    func save(to store: LicenseStore) async -> Bool {
        guard draft.hasValidProductName else {
            showsNameError = true
            return false
        }
        if serialUnreadable, draft.serial.isEmpty {
            failedAction = .save
            errorMessage = String(localized: "The current serial couldn't be read, so saving now would remove it. Enter the serial again, or close the form and try later.")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let saved: LicenseSummary
        do {
            saved = try await store.save(draft, id: license?.id)
        } catch {
            failedAction = .save
            errorMessage = error.localizedDescription
            return false
        }
        // The fields are written: from here a retry must never create the license again, and
        // `original` must match the draft so Cancel does not warn about changes already saved.
        adopt(saved)
        original = draft
        // Fields first, then removals, then adds (R16). The license's own fields are saved even
        // when an attachment fails, and the sheet stays open to say which one.
        return await applyAttachments(to: saved.id, in: store)
    }

    /// Applies the removals and the picked files, in that order.
    ///
    /// Returns true when everything was applied and the sheet can close. On a failure at
    /// attachment *k* of *n* the files written before *k* stay written and are dropped from the
    /// pending list, so a second Save does not write them twice, and the message names the file
    /// that failed and how many were left (R16).
    private func applyAttachments(to licenseID: UUID, in store: LicenseStore) async -> Bool {
        for id in Array(removedAttachmentIDs) {
            do {
                adopt(try await store.removeAttachment(id: id))
            } catch {
                failedAction = .save
                errorMessage = String(
                    localized: "The license was saved, but an attachment couldn't be removed: \(error.localizedDescription)")
                return false
            }
            removedAttachmentIDs.remove(id)
        }

        while let pending = pendingAttachments.first {
            do {
                adopt(try await store.addAttachment(pending.file, to: licenseID))
            } catch {
                failedAction = .save
                let remaining = pendingAttachments.count
                errorMessage = remaining > 1
                    ? String(localized: "The license was saved, but \(pending.fileName) couldn't be added: \(error.localizedDescription) \(remaining) files were not added.")
                    : String(localized: "The license was saved, but \(pending.fileName) couldn't be added: \(error.localizedDescription)")
                return false
            }
            pendingAttachments.removeFirst()
        }
        return true
    }

    /// Deletes the edited license. Returns true when the sheet can close.
    func delete(from store: LicenseStore) async -> Bool {
        guard let license else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.delete(id: license.id)
            return true
        } catch {
            failedAction = .delete
            errorMessage = error.localizedDescription
            return false
        }
    }
}
