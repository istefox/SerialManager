import SwiftUI

/// Sidebar: licenses sorted by name, filtered by the search field.
struct LicenseListView: View {
    @Bindable var store: LicenseStore
    var onDelete: ((LicenseSummary) -> Void)?

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
                ContentUnavailableView.search(text: store.searchText)
            }
        }
        .onDeleteCommand {
            if let license = store.selectedLicense { onDelete?(license) }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: Text("Name or vendor"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }
}

struct LicenseRow: View {
    let license: LicenseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(license.productName)
                .font(.headline)
                .lineLimit(2)
            if !license.vendor.isEmpty {
                Text(license.vendor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
#endif
