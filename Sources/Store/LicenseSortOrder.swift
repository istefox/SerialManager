import Foundation

/// The six orders the sidebar offers (SPEC 0018, R1).
///
/// `rawValue` is what `@AppStorage` persists (R3): the strings are part of the stored format and
/// must not be renamed. An unrecognised stored value falls back to `.nameAscending` (R3, A2).
enum LicenseSortOrder: String, CaseIterable, Identifiable, Sendable {
    case nameAscending = "name-ascending"
    case nameDescending = "name-descending"
    case addedNewestFirst = "added-newest"
    case addedOldestFirst = "added-oldest"
    case modifiedNewestFirst = "modified-newest"
    case modifiedOldestFirst = "modified-oldest"

    /// The order used when nothing was ever chosen, and the fallback for a value this build does
    /// not recognise (D10).
    static let `default` = LicenseSortOrder.nameAscending

    /// `@AppStorage` key of the chosen order (R3).
    static let storageKey = "licenseSortOrder"

    /// The stored value as an order. Pure, so the fallback of R3 is testable without `@AppStorage`.
    static func stored(_ rawValue: String?) -> LicenseSortOrder {
        guard let rawValue, let order = LicenseSortOrder(rawValue: rawValue) else { return .default }
        return order
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAscending: String(localized: "Name, A to Z")
        case .nameDescending: String(localized: "Name, Z to A")
        case .addedNewestFirst: String(localized: "Date Added, Newest First")
        case .addedOldestFirst: String(localized: "Date Added, Oldest First")
        case .modifiedNewestFirst: String(localized: "Date Modified, Newest First")
        case .modifiedOldestFirst: String(localized: "Date Modified, Oldest First")
        }
    }

    /// Orders `licenses` by this order, with a tie-breaker chain whose last term is the license
    /// `id`, so two licenses never swap places between two renderings of the same data (R2).
    func apply(to licenses: [LicenseSummary]) -> [LicenseSummary] {
        licenses.sorted(by: isOrderedBefore)
    }

    /// Name comparisons use `localizedStandardCompare`, so "iTunes" and "Itunes" sort together and
    /// "Item 2" precedes "Item 10" (R1).
    func isOrderedBefore(_ lhs: LicenseSummary, _ rhs: LicenseSummary) -> Bool {
        switch self {
        case .nameAscending:
            byName(lhs, rhs, ascending: true)
        case .nameDescending:
            byName(lhs, rhs, ascending: false)
        case .addedNewestFirst:
            byDate(lhs.createdAt, rhs.createdAt, lhs, rhs, newestFirst: true)
        case .addedOldestFirst:
            byDate(lhs.createdAt, rhs.createdAt, lhs, rhs, newestFirst: false)
        case .modifiedNewestFirst:
            byDate(lhs.updatedAt, rhs.updatedAt, lhs, rhs, newestFirst: true)
        case .modifiedOldestFirst:
            byDate(lhs.updatedAt, rhs.updatedAt, lhs, rhs, newestFirst: false)
        }
    }

    /// Name, then `id`. The id tie-break is ascending in both directions on purpose: it is not a
    /// value the user reads, it only has to be stable.
    private func byName(_ lhs: LicenseSummary, _ rhs: LicenseSummary, ascending: Bool) -> Bool {
        switch lhs.productName.localizedStandardCompare(rhs.productName) {
        case .orderedAscending: ascending
        case .orderedDescending: !ascending
        case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Date, then product name ascending, then `id`: two licenses sharing a date fall back to the
    /// default order instead of swapping (R2).
    private func byDate(
        _ left: Date, _ right: Date, _ lhs: LicenseSummary, _ rhs: LicenseSummary, newestFirst: Bool
    ) -> Bool {
        if left != right { return newestFirst ? left > right : left < right }
        return byName(lhs, rhs, ascending: true)
    }
}
