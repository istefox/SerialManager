import SwiftUI

/// Import sheet: password, then the conflict choice when needed, then a summary.
struct ImportView: View {
    @State var model: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch model.phase {
            case .password, .checking:
                passwordForm
            case .conflicts(let preview):
                conflictForm(preview)
            case .importing:
                ProgressView("Importing\u{2026}")
                    .padding(40)
                    .frame(maxWidth: .infinity)
            case .done(let summary):
                SummaryView(systemImage: "checkmark.circle", title: Text("Import Complete")) {
                    Text("Imported: \(summary.imported)")
                    Text("Replaced: \(summary.replaced)")
                    Text("Skipped: \(summary.skipped)")
                } actions: {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                SummaryView(systemImage: "xmark.octagon", title: Text("Import Failed")) {
                    Text(message)
                } actions: {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 460)
    }

    private var passwordForm: some View {
        VStack(spacing: 0) {
        SheetHeader(title: Text("Import Licenses"))
        Form {
            Section {
                LabeledContent("File") {
                    Text(verbatim: model.fileURL.lastPathComponent)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                SecureField("Password", text: $model.password)
                    .onSubmit { Task { await model.unlock() } }
                if let error = model.backupError {
                    Label(Self.message(for: error), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        }
        .navigationTitle(Text("Import Licenses"))
        .disabled(model.phase == .checking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import") { Task { await model.unlock() } }
                        .disabled(!model.canUnlock)
                }
            }
        }
    }

    private func conflictForm(_ preview: ImportPreview) -> some View {
        VStack(spacing: 0) {
        SheetHeader(title: Text("Import Licenses"))
        Form {
            Section {
                Text("Already in SerialManager: \(preview.conflictingIDs.count) of \(preview.licenseCount) licenses.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Existing Licenses", selection: $model.policy) {
                    Text("Skip").tag(ConflictPolicy.skip)
                    Text("Replace").tag(ConflictPolicy.replace)
                }
                .pickerStyle(.segmented)
                Text(model.policy == .skip
                     ? "Your current licenses stay as they are."
                     : "Your current licenses are overwritten with the ones in the backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        }
        .navigationTitle(Text("Import Licenses"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { Task { await model.apply(preview) } }
            }
        }
    }

    static func message(for error: BackupError) -> LocalizedStringKey {
        switch error {
        case .wrongPassword: "The password is incorrect."
        case .corruptedFile: "This file isn't a valid SerialManager backup."
        case .unsupportedVersion: "This backup was made with a newer version of SerialManager."
        }
    }
}

#if DEBUG
@MainActor
private func previewImport(_ phase: ImportModel.Phase = .password, error: BackupError? = nil) -> ImportView {
    let repository = InMemoryLicenseRepository.sample()
    let model = ImportModel(
        fileURL: URL(fileURLWithPath: "/tmp/SerialManager Backup 2026-01-01.smbackup"),
        service: InMemoryBackupService(repository: repository),
        store: LicenseStore(repository: repository, initial: SampleData.licenses),
        phase: phase,
        backupError: error
    )
    return ImportView(model: model)
}

private let samplePreview = ImportPreview(
    fileURL: URL(fileURLWithPath: "/tmp/Sample.smbackup"),
    licenseCount: 5,
    conflictingIDs: [UUID(), UUID()]
)

#Preview("Import, password") { previewImport() }
#Preview("Import, wrong password") { previewImport(error: .wrongPassword) }
#Preview("Import, corrupted file") { previewImport(error: .corruptedFile) }
#Preview("Import, newer version") { previewImport(error: .unsupportedVersion) }
#Preview("Import, conflicts") { previewImport(.conflicts(samplePreview)) }
#Preview("Import, importing") { previewImport(.importing) }
#Preview("Import, done") { previewImport(.done(ImportSummary(imported: 3, replaced: 0, skipped: 2))) }
#Preview("Import, failed") { previewImport(.failed("The file couldn't be read (sample error).")) }
#endif
