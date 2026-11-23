import SwiftUI

/// Read-only record card of one license.
struct LicenseDetailView: View {
    let license: LicenseSummary
    let store: LicenseStore
    var router: AppRouter?
    var onAddSerial: (() -> Void)?
    /// Injected so a preview or a test never launches another application (R9, A18).
    var opener = AttachmentOpener()

    @AppStorage(ClipboardSettings.delayKey) private var clearDelay = ClipboardSettings.defaultDelay
    @State private var lookup: LicenseStore.SerialLookup = .loading
    @State private var isRevealed = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Product") {
                LabeledContent("Name") {
                    Text(license.productName).textSelection(.enabled)
                }
                optionalRow("Vendor", license.vendor)
                optionalRow("Version", license.version)
            }
            Section("License") {
                SerialRow(
                    lookup: lookup,
                    isRevealed: $isRevealed,
                    showsCopied: showsCopied,
                    onCopy: copySerial,
                    onAddSerial: onAddSerial
                )
                optionalRow("Registered Name", license.registeredName)
                optionalRow("Registered Email", license.registeredEmail)
                if let date = license.purchaseDate {
                    LabeledContent("Purchase Date") {
                        Text(date, format: .dateTime.day().month(.wide).year())
                    }
                }
            }
            if !license.attachments.isEmpty {
                AttachmentsDetailSection(license: license, store: store, opener: opener)
            }
            if !license.notes.isEmpty {
                Section("Notes") {
                    Text(license.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Created \(license.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Modified \(license.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(license.productName)
        .task(id: TaskKey(id: license.id, updatedAt: license.updatedAt)) {
            isRevealed = false
            lookup = .loading
            lookup = await store.serial(for: license.id)
        }
        .onChange(of: router?.request) { _, request in
            switch request?.command {
            case .copySerial: copySerial()
            case .toggleSerial: if case .present = lookup { isRevealed.toggle() }
            default: break
            }
        }
    }

    private func copySerial() {
        guard case .present(let serial) = lookup else { return }
        let changeCount = Clipboard.copySecret(serial)
        Clipboard.scheduleClear(after: clearDelay, changeCount: changeCount)
        AccessibilityNotification.Announcement(String(localized: "Serial copied")).post()
        showsCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    @ViewBuilder
    private func optionalRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(value).textSelection(.enabled)
            }
        }
    }

    /// Reloads the serial when the selection changes or the license is saved.
    private struct TaskKey: Equatable {
        let id: UUID
        let updatedAt: Date
    }
}

#if DEBUG
#Preview("Detail") {
    LicenseDetailView(license: SampleData.first, store: .preview())
        .frame(width: 520, height: 520)
}

#Preview("Detail, serial missing") {
    LicenseDetailView(license: SampleData.missingSerial, store: .preview(), onAddSerial: {})
        .frame(width: 520, height: 520)
}
#endif
