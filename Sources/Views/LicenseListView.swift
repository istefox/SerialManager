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
            if !license.vendor.isEmpty {
                Text(license.vendor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

#Preview("List, long names") {
    let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
    func entry(_ name: String, vendor: String) -> (LicenseSummary, String?) {
        let license = LicenseSummary(
            id: UUID(), productName: name, vendor: vendor, registeredEmail: "user@example.com",
            purchaseDate: date, version: "1.0", notes: "", createdAt: date, updatedAt: date
        )
        return (license, "FAKE-0000-TEST")
    }
    let entries = [
        entry("Fictional Backup Pro Enterprise Edition Twenty Twenty-Six",
              vendor: "Example Software Distribution Company"),
        entry("Alpha Test Tool", vendor: "Example Corp"),
    ]
    // The sidebar at its minimum width (220 pt).
    return NavigationStack {
        LicenseListView(store: .preview(entries: entries))
    }
    .frame(width: 220, height: 440)
}
#endif
