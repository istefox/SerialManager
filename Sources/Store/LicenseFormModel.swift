import Foundation
import Observation

/// State of the license form sheet, for both New License and Edit License.
@MainActor
@Observable
final class LicenseFormModel {
    /// The license being edited; nil for a new one.
    let license: LicenseSummary?
    var draft: LicenseDraft
    private(set) var original: LicenseDraft
    var showsNameError = false
    private(set) var isSaving = false
    private(set) var isLoadingSerial: Bool
    /// True when the current serial could not be read: saving an empty serial would erase it.
    private(set) var serialUnreadable = false
    var errorMessage: String?

    init(license: LicenseSummary? = nil, draft: LicenseDraft? = nil) {
        self.license = license
        let start = draft ?? license.map { LicenseDraft($0, serial: nil) } ?? LicenseDraft()
        self.draft = start
        self.original = start
        self.isLoadingSerial = license != nil && draft == nil
    }

    var isEditing: Bool { license != nil }
    var hasChanges: Bool { draft != original }

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
            errorMessage = String(localized: "The current serial couldn't be read, so saving now would remove it. Enter the serial again, or close the form and try later.")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.save(draft, id: license?.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
            errorMessage = error.localizedDescription
            return false
        }
    }
}
