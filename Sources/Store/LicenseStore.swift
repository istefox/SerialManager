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
    var selection: LicenseSummary.ID? {
        // A newly selected entry has no serial in the detail until its lookup completes.
        didSet { if selection != oldValue, let selection { detailSerialFound[selection] = nil } }
    }

    /// Whether the detail view found the serial of each entry, as of its last lookup.
    /// Drives Copy Serial and Show or Hide Serial in the License menu.
    private(set) var detailSerialFound: [LicenseSummary.ID: Bool] = [:]

    @ObservationIgnored private let repository: any LicenseRepository

    /// Pass `initial` to start already loaded (previews); otherwise call `load()`.
    init(repository: any LicenseRepository, initial: [LicenseSummary]? = nil) {
        self.repository = repository
        if let initial {
            licenses = Self.sorted(initial)
            phase = .loaded
        }
    }

    /// Licenses matching the search text, sorted by product name.
    var visibleLicenses: [LicenseSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return licenses }
        return licenses.filter {
            $0.productName.localizedStandardContains(query) || $0.vendor.localizedStandardContains(query)
        }
    }

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
            licenses = Self.sorted(try await repository.fetchAll())
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
    @discardableResult
    func save(_ draft: LicenseDraft, id: LicenseSummary.ID? = nil) async throws -> LicenseSummary {
        let clean = draft.normalized
        let saved: LicenseSummary
        if let id {
            saved = try await repository.update(id: id, with: clean)
            licenses.removeAll { $0.id == id }
        } else {
            saved = try await repository.create(clean)
        }
        licenses = Self.sorted(licenses + [saved])
        selection = saved.id
        return saved
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

    static func sorted(_ licenses: [LicenseSummary]) -> [LicenseSummary] {
        licenses.sorted {
            $0.productName.localizedStandardCompare($1.productName) == .orderedAscending
        }
    }
}
