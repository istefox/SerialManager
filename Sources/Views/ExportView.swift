import SwiftUI

/// Export sheet: password twice, save panel, then a summary.
struct ExportView: View {
    @State var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch model.phase {
            case .entering, .exporting:
                passwordForm
            case .done(let summary, let url):
                SummaryView(systemImage: "checkmark.circle", title: Text("Backup Exported")) {
                    Text("Exported \(summary.licenseCount) licenses.")
                    if summary.missingSerialCount > 0 {
                        Text("Without a serial in the Keychain: \(summary.missingSerialCount)")
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    Button("Show in Finder") { BackupFilePanels.showInFinder(url) }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                SummaryView(systemImage: "xmark.octagon", title: Text("Export Failed")) {
                    Text(message)
                } actions: {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Try Again") { model.retry() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 460)
    }

    private var passwordForm: some View {
        VStack(spacing: 0) {
        SheetHeader(title: Text("Export Licenses"))
        Form {
            Section {
                Text("The backup contains all your licenses and serials, encrypted with this password. You need it to restore the backup: it can't be recovered if you forget it.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $model.password)
                SecureField("Confirm Password", text: $model.confirmation)
                // Repeats ExportModel.minimumPasswordLength: change the two together.
                Text("Use at least 12 characters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.showsMismatch {
                    Label("The passwords don't match.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        }
        .navigationTitle(Text("Export Licenses"))
        .disabled(model.phase == .exporting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .exporting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Export\u{2026}") {
                        guard let url = BackupFilePanels.chooseExportURL() else { return }
                        Task { await model.export(to: url) }
                    }
                    .disabled(!model.canExport)
                }
            }
        }
    }
}

/// Result layout shared by the export and import sheets.
struct SummaryView<Content: View, Actions: View>: View {
    let systemImage: String
    let title: Text
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            title.font(.headline)
            VStack(spacing: 4) { content }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack { actions }
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
private let previewService = InMemoryBackupService(repository: .sample())

#Preview("Export, entering") {
    ExportView(model: ExportModel(service: previewService))
}

#Preview("Export, short password") {
    let model = ExportModel(service: previewService)
    model.password = "short-pass"
    model.confirmation = "short-pass"
    return ExportView(model: model)
}

#Preview("Export, mismatch") {
    let model = ExportModel(service: previewService)
    model.password = "sample-backup-one"
    model.confirmation = "sample-backup-two"
    return ExportView(model: model)
}

#Preview("Export, exporting") {
    ExportView(model: ExportModel(service: previewService, phase: .exporting))
}

#Preview("Export, done") {
    ExportView(model: ExportModel(
        service: previewService,
        phase: .done(ExportSummary(licenseCount: 5, missingSerialCount: 1),
                     URL(fileURLWithPath: "/tmp/Sample.smbackup"))
    ))
}

#Preview("Export, failed") {
    ExportView(model: ExportModel(service: previewService, phase: .failed("The disk is full (sample error).")))
}
#endif
