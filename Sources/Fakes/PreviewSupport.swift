import Foundation

#if DEBUG

@MainActor
extension LicenseStore {
    /// Store already loaded with the sample licenses, for previews.
    static func preview(
        entries: [(LicenseSummary, String?)] = SampleData.entries,
        selection: LicenseSummary.ID? = nil,
        searchText: String = ""
    ) -> LicenseStore {
        let store = LicenseStore(
            repository: InMemoryLicenseRepository(entries: entries),
            initial: entries.map(\.0)
        )
        store.selection = selection
        store.searchText = searchText
        return store
    }
}
#endif
