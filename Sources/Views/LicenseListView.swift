import SwiftUI

/// Sidebar: licenses in the chosen order, filtered by the search field and its scope.
struct LicenseListView: View {
    @Bindable var store: LicenseStore
    var onDelete: ((LicenseSummary) -> Void)?

    /// The chosen order, persisted across launches (R3). The store holds the same value so that
    /// `visibleLicenses` and every save sort by one rule; this is the copy that survives a quit.
    @AppStorage(LicenseSortOrder.storageKey) private var storedSortOrder = LicenseSortOrder.default.rawValue

    var body: some View {
        let visible = store.visibleLicenses
        List(visible, selection: $store.selection) { license in
            LicenseRow(license: license)
                .tag(license.id)
        }
        .overlay {
            if store.phase == .loading {
                ProgressView()
            } else if visible.isEmpty, !store.licenses.isEmpty {
                emptySearchState
            }
        }
        .onDeleteCommand {
            if let license = store.selectedLicense { onDelete?(license) }
        }
        .searchable(
            text: $store.searchText, placement: .sidebar, prompt: Text(store.searchScope.prompt))
        .toolbar {
            ToolbarItem {
                sortMenu
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        // Both directions, so a value typed into defaults by hand, or written by another window,
        // still reaches the store, and the picker writes through to defaults (R3).
        .onAppear { store.sortOrder = LicenseSortOrder.stored(storedSortOrder) }
        .onChange(of: storedSortOrder) { _, raw in
            store.sortOrder = LicenseSortOrder.stored(raw)
        }
        .onChange(of: store.sortOrder) { _, order in
            if storedSortOrder != order.rawValue { storedSortOrder = order.rawValue }
        }
    }

    /// Order and scope in one menu, so the 220 pt sidebar keeps its width (R3, R5).
    ///
    /// Changing either leaves `searchText` and `selection` untouched: the list is reordered or
    /// refiltered around the same selected license, which `List` keeps scrolled into view.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $storedSortOrder) {
                ForEach(LicenseSortOrder.allCases) { order in
                    Text(order.label).tag(order.rawValue)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Search In", selection: $store.searchScope) {
                ForEach(LicenseSearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort and Search Options", systemImage: "line.3.horizontal.decrease")
        }
        .help(Text("Sorted by \(LicenseSortOrder.stored(storedSortOrder).label)"))
    }

    /// The no-results state. With a scope other than All Fields it says which field was searched
    /// and offers the way back, so a filter set earlier is never mistaken for an empty library (R6).
    @ViewBuilder
    private var emptySearchState: some View {
        if store.isSearchScoped {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No license has \(store.searchText) in \(store.searchScope.label).")
            } actions: {
                Button("Search All Fields") { store.searchScope = .all }
            }
        } else {
            ContentUnavailableView.search(text: store.searchText)
        }
    }
}

struct LicenseRow: View {
    let license: LicenseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A sidebar List limits row text to one line: lift it so long names wrap (SPEC 0005, D3).
            Text(license.productName)
                .font(.headline)
                .lineLimit(nil)
            if !license.vendor.isEmpty {
                Text(license.vendor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("List") {
    NavigationSplitView {
        LicenseListView(store: .preview())
    } detail: {
        EmptyView()
    }
}

#Preview("List, search without results") {
    NavigationSplitView {
        LicenseListView(store: .preview(searchText: "no such product"))
    } detail: {
        EmptyView()
    }
}

#Preview("List, no results in a scoped search") {
    NavigationSplitView {
        LicenseListView(store: .preview(searchText: "no such vendor", searchScope: .vendor))
    } detail: {
        EmptyView()
    }
    .frame(width: 720, height: 440)
}

#Preview("List, newest first") {
    NavigationSplitView {
        LicenseListView(store: .preview(sortOrder: .addedNewestFirst))
    } detail: {
        EmptyView()
    }
    .frame(width: 720, height: 440)
}

#Preview("List, long names") {
    NavigationSplitView {
        LicenseListView(store: .preview(entries: longNameEntries))
    } detail: {
        EmptyView()
    }
    .frame(width: 720, height: 440)
}

#Preview("Rows, long names, sidebar at 220 pt") {
    // The same rows in a split-view sidebar pinned at its minimum width.
    NavigationSplitView {
        List(longNameEntries.map(\.0)) { LicenseRow(license: $0) }
            .navigationSplitViewColumnWidth(220)
    } detail: {
        EmptyView()
    }
    .frame(width: 720, height: 440)
}

/// Fake entries local to the long-name previews, kept out of `SampleData` (SPEC 0005, E7).
private let longNameEntries: [(LicenseSummary, String?)] = {
    let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
    func entry(_ name: String, vendor: String) -> (LicenseSummary, String?) {
        let license = LicenseSummary(
            id: UUID(), productName: name, vendor: vendor, registeredName: "Jane Appleseed",
            registeredEmail: "user@example.com",
            purchaseDate: date, version: "1.0", notes: "", createdAt: date, updatedAt: date
        )
        return (license, "FAKE-0000-TEST")
    }
    return [
        entry("Fictional Backup Pro Enterprise Edition Twenty Twenty-Six",
              vendor: "Example Software Distribution Company"),
        entry("Alpha Test Tool", vendor: "Example Corp"),
    ]
}()
#endif
