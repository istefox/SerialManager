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
    var selection: LicenseSummary.ID?

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
        if selection == id { selection = nil }
    }

    func serial(for id: LicenseSummary.ID) async -> SerialLookup {
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
