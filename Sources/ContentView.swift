import SwiftUI

/// Main window: license list in the sidebar, the selected license in the detail.
struct ContentView: View {
    @Bindable var store: LicenseStore
    @Bindable var router: AppRouter
    let backupService: any BackupService

    @State private var formRequest: FormRequest?
    @State private var pendingDelete: LicenseSummary?
    @State private var actionError: String?

    /// What the license sheet opens with.
    struct FormRequest: Identifiable {
        let id = UUID()
        var license: LicenseSummary?
        var focusSerial = false
    }

    var body: some View {
        NavigationSplitView {
            LicenseListView(store: store) { pendingDelete = $0 }
                .toolbar {
                    ToolbarItem {
                        Button {
                            newLicense()
                        } label: {
                            Label("New License", systemImage: "plus")
                        }
                        .help(Text("New License"))
                        .disabled(store.phase != .loaded)
                    }
                }
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 440)
        .sheet(item: $formRequest) { request in
            LicenseFormView(
                store: store,
                model: LicenseFormModel(license: request.license),
                focusSerial: request.focusSerial
            )
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .export:
                ExportView(model: ExportModel(service: backupService))
            case .importBackup(let url):
                ImportView(model: ImportModel(fileURL: url, service: backupService, store: store))
            }
        }
        .confirmationDialog(
            DeleteConfirmation.title(for: pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { license in
            Button("Delete", role: .destructive) { Task { await delete(license) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            DeleteConfirmation.message
        }
        .alert(
            "Couldn't Delete the License",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            if store.phase == .loading { await store.load() }
        }
        .onChange(of: router.request) { _, request in
            guard let command = request?.command else { return }
            switch command {
            case .newLicense:
                if formRequest == nil { newLicense() }
            case .editLicense:
                if formRequest == nil, let license = store.selectedLicense {
                    formRequest = FormRequest(license: license)
                }
            case .deleteLicense:
                pendingDelete = store.selectedLicense
            case .copySerial, .toggleSerial:
                break // handled by the detail view
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.phase {
        case .loading:
            Color.clear
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Licenses", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await store.load() } }
            }
        case .loaded:
            if store.licenses.isEmpty {
                ContentUnavailableView {
                    Label("No Licenses", systemImage: "key.horizontal")
                } description: {
                    Text("Add the serial numbers of your software to find them here.")
                } actions: {
                    Button("Add License") { newLicense() }
                }
            } else if let license = store.selectedLicense {
                LicenseDetailView(license: license, store: store, router: router) {
                    formRequest = FormRequest(license: license, focusSerial: true)
                }
                .toolbar { detailToolbar(for: license) }
            } else {
                ContentUnavailableView(
                    "Select a License",
                    systemImage: "sidebar.left",
                    description: Text("Choose a license from the list to see its details.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(for license: LicenseSummary) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                formRequest = FormRequest(license: license)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .help(Text("Edit License"))
            Button {
                pendingDelete = license
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help(Text("Delete License"))
        }
    }

    private func newLicense() {
        formRequest = FormRequest()
    }

    private func delete(_ license: LicenseSummary) async {
        do {
            try await store.delete(id: license.id)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

#if DEBUG
extension ContentView {
    static func preview(_ store: LicenseStore) -> ContentView {
        ContentView(store: store, router: AppRouter(),
                    backupService: InMemoryBackupService(repository: .sample()))
    }
}

#Preview("Main, selected") {
    ContentView.preview(.preview(selection: SampleData.first.id))
}

#Preview("Main, no selection") {
    ContentView.preview(.preview())
}

#Preview("Main, empty") {
    ContentView.preview(.preview(entries: []))
}

#Preview("Main, search without results") {
    ContentView.preview(.preview(searchText: "no such product"))
}

#Preview("Main, loading") {
    ContentView.preview(LicenseStore(repository: InMemoryLicenseRepository.sample()))
}

#Preview("Main, load error") {
    struct SampleFailure: LocalizedError {
        var errorDescription: String? { "The license database couldn't be opened (sample error)." }
    }
    return ContentView.preview(LicenseStore(repository: InMemoryLicenseRepository(failure: SampleFailure())))
}

#Preview("Main, Italian") {
    ContentView.preview(.preview(selection: SampleData.first.id))
        .environment(\.locale, Locale(identifier: "it"))
}
#endif
