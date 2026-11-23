import SwiftUI
import UniformTypeIdentifiers

/// The read-only Attachments section of the detail view (SPEC 0018, R18 to R21).
///
/// Absent when the license has no attachment, like the Notes section. Each row offers Open, which
/// hands a decrypted copy to another application (R19), and Save a Copy…, which writes one where
/// the user chooses (R20). A row whose stored file is gone says so and offers to remove it (R13).
struct AttachmentsDetailSection: View {
    let license: LicenseSummary
    let store: LicenseStore
    /// Injected so a test or a preview never launches an application (R9, A18).
    let opener: AttachmentOpener

    /// Which attachments have a readable file. An id absent from the map has not been checked yet
    /// and is shown as readable: the check is a `stat`, not a decryption, and a failed Open still
    /// reports a real error.
    @State private var readable: [UUID: Bool] = [:]
    @State private var busy: UUID?
    @State private var errorMessage: String?
    @State private var exporting: Export?
    @State private var confirmsRemoval: AttachmentSummary?

    /// One attachment on its way to a file the user picks.
    private struct Export: Identifiable {
        let id: UUID
        let fileName: String
        let document: AttachmentDocument
    }

    var body: some View {
        Section("Attachments") {
            ForEach(license.attachments) { attachment in
                row(attachment)
            }
        }
        .task(id: TaskKey(license: license)) {
            // Keyed on the attachment ids as well as `updatedAt`, because an import adds
            // attachments without bumping `updatedAt` (D9, A11).
            await refreshReadability()
        }
        .alert(
            Text("Couldn't Open the Attachment"),
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            Text("Remove “\(confirmsRemoval?.fileName ?? "")”?"),
            isPresented: Binding(
                get: { confirmsRemoval != nil }, set: { if !$0 { confirmsRemoval = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let attachment = confirmsRemoval { remove(attachment) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its file is already missing, so there is nothing left to recover.")
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting?.document,
            contentType: exporting?.document.contentType ?? .data,
            defaultFilename: exporting?.fileName
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exporting = nil
        }
    }

    @ViewBuilder
    private func row(_ attachment: AttachmentSummary) -> some View {
        let isReadable = readable[attachment.id] ?? true
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if isReadable {
                    Text(attachment.addedAt, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("File missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(AttachmentLimits.formatted(attachment.byteCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if busy == attachment.id {
                ProgressView().controlSize(.small)
            } else if isReadable {
                Button("Open") { Task { await open(attachment) } }
                Menu {
                    Button("Save a Copy\u{2026}") { Task { await saveCopy(attachment) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More actions for \(attachment.fileName)"))
            } else {
                Button("Remove") { confirmsRemoval = attachment }
            }
        }
        .disabled(busy != nil)
    }

    // MARK: Actions

    private func open(_ attachment: AttachmentSummary) async {
        busy = attachment.id
        defer { busy = nil }
        do {
            let data = try await store.attachmentData(id: attachment.id)
            try opener.open(attachment, data: data)
        } catch {
            errorMessage = error.localizedDescription
            await refreshReadability()
        }
    }

    private func saveCopy(_ attachment: AttachmentSummary) async {
        busy = attachment.id
        defer { busy = nil }
        do {
            let data = try await store.attachmentData(id: attachment.id)
            exporting = Export(
                id: attachment.id,
                fileName: attachment.fileName,
                document: AttachmentDocument(data: data, contentType: attachment.contentType))
        } catch {
            errorMessage = error.localizedDescription
            await refreshReadability()
        }
    }

    private func remove(_ attachment: AttachmentSummary) {
        Task {
            busy = attachment.id
            defer { busy = nil }
            do {
                _ = try await store.removeAttachment(id: attachment.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshReadability() async {
        var found: [UUID: Bool] = [:]
        for attachment in license.attachments {
            found[attachment.id] = await store.attachmentIsReadable(id: attachment.id)
        }
        readable = found
    }

    /// Re-runs the readability check when the license is saved AND when its attachments change
    /// without a save, which an import does (A11).
    private struct TaskKey: Equatable {
        let id: UUID
        let updatedAt: Date
        let attachmentIDs: [UUID]

        init(license: LicenseSummary) {
            id = license.id
            updatedAt = license.updatedAt
            attachmentIDs = license.attachments.map(\.id)
        }
    }
}

/// One decrypted attachment on its way to a file the user picks (R20).
///
/// A plain value holding the plaintext only for as long as the save sheet is open.
struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data
    let contentType: UTType

    init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType.flatMap(UTType.init) ?? .data
    }

    init(configuration: ReadConfiguration) throws {
        // Never read back: the app only ever writes a copy out.
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#if DEBUG
#Preview("Attachments, detail") {
    Form {
        AttachmentsDetailSection(
            license: SampleData.withAttachments,
            store: .preview(),
            opener: AttachmentOpener(
                directory: FileManager.default.temporaryDirectory
                    .appending(path: "PreviewAttachments"),
                openFile: { _ in true }))
    }
    .formStyle(.grouped)
    .frame(width: 520)
}
#endif
