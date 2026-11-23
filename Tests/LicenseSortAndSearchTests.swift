import Foundation
import Testing
@testable import SerialManager

/// The six orders and the search scopes (SPEC 0018, A1 to A4, R1 to R7).
///
/// Pure functions over `LicenseSummary` values: no store, no repository, no Keychain. The sorted
/// order is asserted by product name because the fixtures' names are unique; the tie-breaker cases
/// assert the whole sequence. Sample values are obviously fake.
struct LicenseSortAndSearchTests {

    // MARK: Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    /// Ids ordered by `uuidString`, so a test can state what the final tie-breaker must do.
    private static let ids: [UUID] = (1...6).map {
        UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")!
    }

    private static func license(
        _ index: Int,
        _ name: String,
        vendor: String = "",
        registeredName: String = "",
        registeredEmail: String = "",
        version: String = "",
        notes: String = "",
        created: TimeInterval = 0,
        modified: TimeInterval = 0,
        attachments: [String] = []
    ) -> LicenseSummary {
        LicenseSummary(
            id: ids[index], productName: name, vendor: vendor, registeredName: registeredName,
            registeredEmail: registeredEmail, purchaseDate: nil, version: version, notes: notes,
            createdAt: epoch.addingTimeInterval(created),
            updatedAt: epoch.addingTimeInterval(modified),
            attachments: attachments.enumerated().map { offset, name in
                AttachmentSummary(
                    id: UUID(), fileName: name, byteCount: 10, contentType: nil,
                    addedAt: epoch.addingTimeInterval(Double(offset)))
            }
        )
    }

    /// Three names plus the pair that differs only by case, and two licenses sharing a `createdAt`.
    ///
    /// "itunes" and "iTunes" must sort together under `localizedStandardCompare`, and
    /// "Item 2" must precede "Item 10", which a plain `<` would get wrong.
    private static let mixed: [LicenseSummary] = [
        license(0, "iTunes", created: 300, modified: 100),
        license(1, "itunes", created: 100, modified: 500),   // same createdAt as index 2
        license(2, "Item 10", created: 100, modified: 200),  // same createdAt as index 1
        license(3, "Item 2", created: 400, modified: 400),
        license(4, "Alpha", created: 200, modified: 300),
    ]

    private func names(_ licenses: [LicenseSummary]) -> [String] {
        licenses.map(\.productName)
    }

    // MARK: A1, the six orders

    @Test("Each of the six orders produces the expected sequence")
    func sixOrders() {
        let input = Self.mixed

        #expect(names(LicenseSortOrder.nameAscending.apply(to: input))
            == ["Alpha", "Item 2", "Item 10", "itunes", "iTunes"])
        #expect(names(LicenseSortOrder.nameDescending.apply(to: input))
            == ["iTunes", "itunes", "Item 10", "Item 2", "Alpha"])
        #expect(names(LicenseSortOrder.addedNewestFirst.apply(to: input))
            == ["Item 2", "iTunes", "Alpha", "Item 10", "itunes"])
        #expect(names(LicenseSortOrder.addedOldestFirst.apply(to: input))
            == ["Item 10", "itunes", "Alpha", "iTunes", "Item 2"])
        #expect(names(LicenseSortOrder.modifiedNewestFirst.apply(to: input))
            == ["itunes", "Item 2", "Alpha", "Item 10", "iTunes"])
        #expect(names(LicenseSortOrder.modifiedOldestFirst.apply(to: input))
            == ["iTunes", "Item 10", "Alpha", "Item 2", "itunes"])
    }

    @Test("A pair of names differing only by case keeps one order, whatever the input order")
    func caseOnlyPairIsStable() {
        // `localizedStandardCompare` does NOT call these two equal: it is case-insensitive for
        // ordering but still orders a case-only pair deterministically, lowercase first. So the
        // pair sorts together, reverses with the direction, and never depends on the input order.
        let pair = [Self.mixed[0], Self.mixed[1]] // iTunes = ids[0], itunes = ids[1]
        let ascending = LicenseSortOrder.nameAscending.apply(to: pair)
        #expect(names(ascending) == ["itunes", "iTunes"])
        #expect(names(LicenseSortOrder.nameDescending.apply(to: pair)) == ["iTunes", "itunes"])
        #expect(LicenseSortOrder.nameAscending.apply(to: pair.reversed()).map(\.id)
            == ascending.map(\.id))
    }

    @Test("Two licenses with the identical name fall back to the id, ascending both ways")
    func identicalNamesFallBackToTheID() {
        // The only case where the name comparison really ties. The id tie-break is ascending in
        // BOTH directions on purpose (R2): it breaks a tie, it is not part of the ordering the
        // user asked for, so no license ever swaps place between two renderings.
        let twins = [
            Self.license(5, "Twin", created: 500),
            Self.license(0, "Twin", created: 100),
        ]
        for order: LicenseSortOrder in [.nameAscending, .nameDescending] {
            #expect(order.apply(to: twins).map(\.id) == [Self.ids[0], Self.ids[5]])
            #expect(order.apply(to: twins.reversed()).map(\.id) == [Self.ids[0], Self.ids[5]])
        }
    }

    @Test("Two licenses sharing a date fall back to the name, then to the id")
    func equalDatesFallBack() {
        // ids[1] is "itunes", ids[2] is "Item 10", both created at +100: the name decides, so
        // "Item 10" comes first in both date directions.
        let sameDay = [Self.mixed[1], Self.mixed[2]]
        #expect(names(LicenseSortOrder.addedOldestFirst.apply(to: sameDay)) == ["Item 10", "itunes"])
        #expect(names(LicenseSortOrder.addedNewestFirst.apply(to: sameDay)) == ["Item 10", "itunes"])

        // Same date AND the identical name: only the id is left, ascending in both directions.
        let twins = [
            Self.license(5, "Twin", created: 100),
            Self.license(0, "Twin", created: 100),
        ]
        #expect(LicenseSortOrder.addedNewestFirst.apply(to: twins).map(\.id)
            == [Self.ids[0], Self.ids[5]])
        #expect(LicenseSortOrder.addedOldestFirst.apply(to: twins).map(\.id)
            == [Self.ids[0], Self.ids[5]])
    }

    @Test("Sorting the same data twice gives the identical order")
    func ordersAreStableAcrossCalls() {
        for order in LicenseSortOrder.allCases {
            let first = order.apply(to: Self.mixed)
            let second = order.apply(to: first)
            let third = order.apply(to: Self.mixed.reversed())
            #expect(first.map(\.id) == second.map(\.id), "\(order.rawValue) is not idempotent")
            #expect(first.map(\.id) == third.map(\.id), "\(order.rawValue) depends on input order")
        }
    }

    // MARK: A2, the stored value

    @Test("An unrecognised or missing stored order falls back to product name ascending")
    func storedFallback() {
        #expect(LicenseSortOrder.stored(nil) == .nameAscending)
        #expect(LicenseSortOrder.stored("") == .nameAscending)
        #expect(LicenseSortOrder.stored("name-ascending") == .nameAscending)
        #expect(LicenseSortOrder.stored("price-descending") == .nameAscending)
        #expect(LicenseSortOrder.stored("NAME-DESCENDING") == .nameAscending)
        // Every real raw value survives a round trip, so a stored order keeps working when the
        // labels change.
        for order in LicenseSortOrder.allCases {
            #expect(LicenseSortOrder.stored(order.rawValue) == order)
        }
    }

    // MARK: A3, All Fields

    /// One license carrying a distinct sample value in each of the seven fields of R4.
    private static let wide = license(
        0, "Sample Pro",
        vendor: "Exemplar Software",
        registeredName: "Jane Appleseed",
        registeredEmail: "jane@example.com",
        version: "4.2.1",
        notes: "Upgraded from the trial.",
        attachments: ["Licence-Cafe\u{0301}.pdf"]
    )

    @Test(
        "All Fields matches each of the seven fields in turn",
        arguments: [
            "ample Pro",     // productName
            "xemplar",       // vendor
            "Appleseed",     // registeredName
            "jane@example",  // registeredEmail
            "4.2",           // version
            "the trial",     // notes
            "Licence",       // attachment file name
        ]
    )
    func allFieldsMatchesEveryField(query: String) {
        #expect(LicenseSearchScope.all.matches(Self.wide, query: query))
    }

    @Test("All Fields ignores case and diacritics, and matches nothing it should not")
    func allFieldsIgnoresCaseAndDiacritics() {
        #expect(LicenseSearchScope.all.matches(Self.wide, query: "SAMPLE PRO"))
        #expect(LicenseSearchScope.all.matches(Self.wide, query: "licence-cafe.pdf"))
        #expect(LicenseSearchScope.all.matches(Self.wide, query: "LICENCE-CAF\u{00C9}"))
        // Not a substring anywhere, and the query is never split into words (D11).
        #expect(!LicenseSearchScope.all.matches(Self.wide, query: "Pro Sample"))
        #expect(!LicenseSearchScope.all.matches(Self.wide, query: "no such text"))
    }

    @Test("No scope ever matches a serial")
    func serialsAreNeverSearched() {
        // The serial lives in the Keychain and is not part of `LicenseSummary` at all: the proof
        // is that the sample serial of the fixtures matches no license under any scope (R7).
        let store = SampleData.entries
        for scope in LicenseSearchScope.allCases {
            #expect(!store.map(\.0).contains { scope.matches($0, query: "ACME-0000-TEST-0000") })
        }
    }

    @MainActor
    @Test("A whitespace-only query shows every license")
    func blankQueryShowsEverything() {
        let store = LicenseStore.previewStore()
        #expect(store.visibleLicenses.count == store.licenses.count)
        store.searchText = "   \n\t "
        #expect(store.visibleLicenses.count == store.licenses.count)
        store.searchScope = .vendor
        #expect(store.visibleLicenses.count == store.licenses.count)
        // `isSearchScoped` reports the scope, not the query: it only reaches the view through the
        // no-results state, which a blank query can never produce.
        #expect(store.isSearchScoped)
    }

    // MARK: A4, one scope at a time

    @Test("Each scope matches its own field only")
    func scopesMatchOneFieldEach() {
        let field: [LicenseSearchScope: String] = [
            .productName: "ample Pro",
            .vendor: "xemplar",
            .registeredName: "Appleseed",
            .attachmentName: "Licence",
            .notes: "the trial",
        ]
        for (scope, own) in field {
            #expect(scope.matches(Self.wide, query: own), "\(scope.rawValue) misses its own field")
            // Every other field's query must miss.
            for (other, value) in field where other != scope {
                #expect(
                    !scope.matches(Self.wide, query: value),
                    "\(scope.rawValue) matched \(other.rawValue)'s value")
            }
            // And the two fields no scope of R5 covers: a query on them matches All Fields only.
            for value in ["jane@example", "4.2.1"] {
                #expect(!scope.matches(Self.wide, query: value))
                #expect(LicenseSearchScope.all.matches(Self.wide, query: value))
            }
        }
    }

    @MainActor
    @Test("A scope other than All Fields is reported as scoped, so the empty state can say so")
    func scopedFlag() {
        let store = LicenseStore.previewStore()
        store.searchText = "no such product"
        #expect(!store.isSearchScoped)
        #expect(store.visibleLicenses.isEmpty)
        store.searchScope = .productName
        #expect(store.isSearchScoped)
        // Back to All Fields through the empty state's button.
        store.searchScope = .all
        #expect(!store.isSearchScoped)
    }
}

@MainActor
extension LicenseStore {
    /// A loaded store over the sample licenses, for the two tests above that need one.
    fileprivate static func previewStore() -> LicenseStore {
        let store = LicenseStore(
            repository: InMemoryLicenseRepository(entries: SampleData.entries),
            initial: SampleData.entries.map(\.0))
        return store
    }
}
