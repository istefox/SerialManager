import SwiftUI
import UniformTypeIdentifiers

/// The Attachments section of the license form (SPEC 0018, R16 and R17).
///
/// Nothing here writes to the library: picked files are held by the model until Save, removals are
/// marked, and Cancel leaves everything as it was (D13). Its own struct because `LicenseFormView`
/// is already at its size limit.
struct AttachmentsFormSection: View {
    let model: LicenseFormModel
    let store: LicenseStore

    @State private var isPicking = false

    var body: some View {
        Section("Attachments") {
            ForEach(model.keptAttachments) { attachment in
                row(
                    name: attachment.fileName,
                    byteCount: attachment.byteCount,
                    note: nil,
                    remove: { model.toggleRemoval(of: attachment.id) },
                    removeLabel: Text("Remove \(attachment.fileName)")
                )
            }
            ForEach(markedForRemoval) { attachment in
                row(
                    name: attachment.fileName,
                    byteCount: attachment.byteCount,
                    note: Text("Will be removed when you save"),
                    remove: { model.toggleRemoval(of: attachment.id) },
                    removeLabel: Text("Keep \(attachment.fileName)"),
                    removeIcon: "arrow.uturn.backward"
                )
            }
            ForEach(model.pendingAttachments) { pending in
                row(
                    name: pending.fileName,
                    byteCount: pending.byteCount,
                    note: Text("Will be added when you save"),
                    remove: { model.cancelPendingAttachment(id: pending.id) },
                    removeLabel: Text("Don't add \(pending.fileName)")
                )
            }

            if let message = model.attachmentError {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Add File\u{2026}") { isPicking = true }
                Spacer()
                Text(AttachmentLimits.formatted(model.attachmentBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        // Any file type (R16). Several at once, each checked against the limits in turn.
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            model.clearAttachmentError()
            switch result {
            case .success(let urls):
                for url in urls { model.pickAttachment(at: url, in: store) }
            case .failure(let error):
                model.attachmentError = error.localizedDescription
            }
        }
    }

    /// The stored attachments the user marked, still listed so the mark can be taken back.
    private var markedForRemoval: [AttachmentSummary] {
        (model.license?.attachments ?? []).filter { model.removedAttachmentIDs.contains($0.id) }
    }

    @ViewBuilder
    private func row(
        name: String,
        byteCount: Int,
        note: Text?,
        remove: @escaping () -> Void,
        removeLabel: Text,
        removeIcon: String = "minus.circle"
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(2)
                if let note {
                    note.font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(AttachmentLimits.formatted(byteCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: remove) {
                Image(systemName: removeIcon)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(removeLabel)
        }
    }
}

#if DEBUG
#Preview("Attachments section, empty") {
    Form { AttachmentsFormSection(model: LicenseFormModel(), store: .preview()) }
        .formStyle(.grouped)
        .frame(width: 460)
}

#Preview("Attachments section, with files") {
    Form {
        AttachmentsFormSection(
            model: LicenseFormModel(license: SampleData.withAttachments), store: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
#endif
