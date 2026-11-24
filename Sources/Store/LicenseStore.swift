import Foundation
import Observation

/// State of the main window. Depends only on `LicenseRepository`.
@MainActor
@Observable
final class LicenseStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum SerialLookup: Equatable {
        case loading
        case present(String)
        case missing
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var licenses: [LicenseSummary] = []
    var searchText = ""
    /// Which field the search matches. Resets to `.all` at every launch (R5), so it is held here
    /// and not in `@AppStorage`.
    var searchScope: LicenseSearchScope = .all
    /// The chosen order. The view keeps this in step with its `@AppStorage` value (R3); the store
    /// holds it so `visibleLicenses` and `save` sort by the same rule.
    var sortOrder: LicenseSortOrder = .default {
        didSet { if sortOrder != oldValue { licenses = sortOrder.apply(to: licenses) } }
    }
    var selection: LicenseSummary.ID? {
        // A newly selected entry has no serial in the detail until its lookup completes.
        didSet { if selection != oldValue, let selection { detailSerialFound[selection] = nil } }
    }

    /// Whether the detail view found the serial of each entry, as of its last lookup.
    /// Drives Copy Serial and Show or Hide Serial in the License menu.
    private(set) var detailSerialFound: [LicenseSummary.ID: Bool] = [:]

    @ObservationIgnored private let repository: any LicenseRepository

    /// Pass `initial` to start already loaded (previews); otherwise call `load()`.
    init(
        repository: any LicenseRepository,
        initial: [LicenseSummary]? = nil,
        sortOrder: LicenseSortOrder = .default
    ) {
        self.repository = repository
        self.sortOrder = sortOrder
        if let initial {
            licenses = sortOrder.apply(to: initial)
            phase = .loaded
        }
    }

    /// Licenses matching the search text in the current scope, in the chosen order.
    ///
    /// A pure function of what the store already holds in memory: no query reaches the Keychain,
    /// and no serial is ever matched (R7). A whitespace-only query shows every license (R4).
    var visibleLicenses: [LicenseSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return licenses }
        return licenses.filter { searchScope.matches($0, query: query) }
    }

    /// True when a scope other than All Fields is narrowing the search, so the empty state can say
    /// which field was searched and offer a way back (R6).
    var isSearchScoped: Bool { searchScope != .all }

    var selectedLicense: LicenseSummary? {
        guard let selection else { return nil }
        return licenses.first { $0.id == selection }
    }

    /// True only when the detail of the selected entry shows its serial (not loading, missing
    /// or failed). Copy Serial and Show or Hide Serial are enabled on this.
    var isSelectedSerialAvailable: Bool {
        guard let id = selectedLicense?.id else { return false }
        return detailSerialFound[id] == true
    }

    var isEmpty: Bool { phase == .loaded && licenses.isEmpty }

    func load() async {
        phase = .loading
        do {
            licenses = sortOrder.apply(to: try await repository.fetchAll())
            if let selection, !licenses.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            phase = .loaded
        } catch {
            licenses = []
            phase = .failed(error.localizedDescription)
        }
    }

    /// Creates a license, or updates it when `id` is given, and selects it.
    ///
    /// `serialUnchanged` is true when the user left the serial exactly as the form loaded it: the
    /// update then leaves the stored serial alone, so saving only other fields never rewrites a
    /// serial imported with outer whitespace and never overwrites or deletes one that changed
    /// since the form opened (SM-01). A serial the user changed or cleared is always trimmed, and
    /// an empty one removes the item.
    @discardableResult
    func save(
        _ draft: LicenseDraft,
        id: LicenseSummary.ID? = nil,
        serialUnchanged: Bool = false
    ) async throws -> LicenseSummary {
        var clean = draft.normalized
        if serialUnchanged { clean.leavesSerialUntouched = true }
        let saved: LicenseSummary
        if let id {
            saved = try await repository.update(id: id, with: clean)
            licenses.removeAll { $0.id == id }
        } else {
            saved = try await repository.create(clean)
        }
        licenses = sortOrder.apply(to: licenses + [saved])
        selection = saved.id
        return saved
    }

    /// Replaces one license in the list, keeping the chosen order and the selection.
    /// Used by the attachment actions, which return the license with its `updatedAt` bumped (D9).
    private func replace(_ license: LicenseSummary) {
        licenses = sortOrder.apply(to: licenses.filter { $0.id != license.id } + [license])
    }

    /// Attaches a file to a license and keeps the list in step.
    @discardableResult
    func addAttachment(_ file: AttachmentFile, to id: LicenseSummary.ID) async throws -> LicenseSummary {
        let saved = try await repository.addAttachment(file, to: id)
        replace(saved)
        return saved
    }

    /// Removes one attachment and keeps the list in step.
    @discardableResult
    func removeAttachment(id: UUID) async throws -> LicenseSummary {
        let saved = try await repository.removeAttachment(id: id)
        replace(saved)
        return saved
    }

    /// The plaintext bytes of one attachment, decrypted on demand.
    /// Whether the stored file of an attachment is still there (R13, R21). A `stat`, no
    /// decryption and no Keychain call, so the detail view can ask for every row it shows.
    func attachmentIsReadable(id: UUID) async -> Bool {
        await repository.attachmentIsReadable(id: id)
    }

    func attachmentData(id: UUID) async throws -> Data {
        try await repository.attachmentData(id: id)
    }

    /// Plaintext bytes of every attachment in the library, for the total of D4. Read from what the
    /// store already holds, so the form can refuse a file without a repository call (R16).
    var libraryAttachmentBytes: Int {
        licenses.reduce(0) { $0 + $1.attachmentBytes }
    }

    func delete(id: LicenseSummary.ID) async throws {
        try await repository.delete(id: id)
        licenses.removeAll { $0.id == id }
        detailSerialFound[id] = nil
        if selection == id { selection = nil }
    }

    /// The serial shown by the detail view. Also records the result for the License menu
    /// (`isSelectedSerialAvailable`), so call it only from `LicenseDetailView`; every other
    /// reader uses `serialWithoutRecording(for:)`. The last call to complete wins.
    func serial(for id: LicenseSummary.ID) async -> SerialLookup {
        detailSerialFound[id] = false
        let result = await serialWithoutRecording(for: id)
        if case .present = result {
            detailSerialFound[id] = true
        } else {
            detailSerialFound[id] = false
        }
        return result
    }

    /// The serial, with no effect on the License menu (for example the edit form's prefill).
    func serialWithoutRecording(for id: LicenseSummary.ID) async -> SerialLookup {
        do {
            if let serial = try await repository.serial(for: id) { return .present(serial) }
            return .missing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The default order, kept as a static so the existing callers and tests of #5 still read.
    static func sorted(_ licenses: [LicenseSummary]) -> [LicenseSummary] {
        LicenseSortOrder.default.apply(to: licenses)
    }
}
