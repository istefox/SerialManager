import SwiftUI

/// Sheet to create or edit a license.
struct LicenseFormView: View {
    let store: LicenseStore
    @State var model: LicenseFormModel
    var focusSerial = false

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false

    enum Field: Hashable { case name, serial }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: model.isEditing ? Text("Edit License") : Text("New License"))
            fields
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 560)
        .navigationTitle(model.isEditing ? Text("Edit License") : Text("New License"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(model.isSaving || model.isLoadingSerial)
            }
        }
        .disabled(model.isSaving)
        .interactiveDismissDisabled(model.hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your changes to this license will be lost.")
        }
        .confirmationDialog(
            DeleteConfirmation.title(for: model.license),
            isPresented: $confirmsDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { if await model.delete(from: store) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            DeleteConfirmation.message
        }
        .alert(
            model.failedAction == .delete
                ? Text("Couldn't Delete the License")
                : Text("Couldn't Save the License"),
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            focus = focusSerial ? .serial : .name
            await model.loadSerial(from: store)
            if focusSerial { focus = .serial }
        }
    }

    private var fields: some View {
        Form {
            Section("Product") {
                TextField("Product Name", text: $model.draft.productName)
                    .focused($focus, equals: .name)
                    .onChange(of: model.draft.productName) {
                        if model.draft.hasValidProductName { model.showsNameError = false }
                    }
                if model.showsNameError {
                    Label("Product name is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                TextField("Vendor", text: $model.draft.vendor)
                TextField("Version", text: $model.draft.version)
            }
            Section("License") {
                ZStack(alignment: .trailing) {
                    TextField("Serial", text: $model.draft.serial, axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(1...4)
                        .focused($focus, equals: .serial)
                        .disabled(model.isLoadingSerial)
                    if model.isLoadingSerial {
                        ProgressView().controlSize(.small)
                    }
                }
                TextField("Registered Email", text: $model.draft.registeredEmail)
                    .textContentType(.emailAddress)
                Toggle("Purchase Date", isOn: $model.hasPurchaseDate)
                if let date = model.draft.purchaseDate {
                    DatePicker(
                        "Date",
                        selection: Binding(get: { date }, set: { model.draft.purchaseDate = $0 }),
                        displayedComponents: .date
                    )
                }
            }
            Section("Notes") {
                TextField("Notes", text: $model.draft.notes, axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
            }
            if model.isEditing {
                Section {
                    Button("Delete License\u{2026}", role: .destructive) { confirmsDelete = true }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func cancel() {
        if model.hasChanges { confirmsDiscard = true } else { dismiss() }
    }

    private func save() async {
        if await model.save(to: store) {
            dismiss()
        } else if model.showsNameError {
            focus = .name
        }
    }
}

/// Shared wording of the delete confirmation, used by the form and the main window.
enum DeleteConfirmation {
    static func title(for license: LicenseSummary?) -> Text {
        Text("Delete \u{201C}\(license?.productName ?? "")\u{201D}?")
    }

    static var message: Text {
        Text("This also removes its serial from the Keychain. This can't be undone.")
    }
}

#if DEBUG
#Preview("Form, new") {
    LicenseFormView(store: .preview(), model: LicenseFormModel())
}

#Preview("Form, name required") {
    let model = LicenseFormModel()
    model.showsNameError = true
    return LicenseFormView(store: .preview(), model: model)
}

#Preview("Form, edit") {
    LicenseFormView(store: .preview(), model: LicenseFormModel(license: SampleData.first))
}

#Preview("Form, edit with changes") {
    var draft = LicenseDraft(SampleData.first, serial: "ACME-0000-TEST-0000")
    draft.version = "4.0"
    draft.notes = "Upgraded (sample)."
    return LicenseFormView(
        store: .preview(),
        model: LicenseFormModel(license: SampleData.first, draft: draft)
    )
}

#Preview("Form, add missing serial") {
    LicenseFormView(
        store: .preview(),
        model: LicenseFormModel(license: SampleData.missingSerial),
        focusSerial: true
    )
}

#Preview("Form, save error") {
    let model = LicenseFormModel(license: SampleData.first, draft: LicenseDraft(SampleData.first, serial: nil))
    model.errorMessage = "The license couldn't be written (sample error)."
    return LicenseFormView(store: .preview(), model: model)
}
#endif
