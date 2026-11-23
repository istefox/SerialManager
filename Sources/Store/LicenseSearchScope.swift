import Foundation

/// Which field the sidebar search matches (SPEC 0018, R5).
///
/// Not persisted across launches on purpose: it resets to `.all`, so a search never silently
/// returns nothing because of a filter set days ago. No scope reaches the Keychain: a serial is
/// never searched (R7).
enum LicenseSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case productName
    case vendor
    case registeredName
    case attachmentName
    case notes

    var id: String { rawValue }

    /// Name of the scope in the picker.
    var label: String {
        switch self {
        case .all: String(localized: "All Fields")
        case .productName: String(localized: "Product Name")
        case .vendor: String(localized: "Vendor")
        case .registeredName: String(localized: "Registered Name")
        case .attachmentName: String(localized: "Attachment Name")
        case .notes: String(localized: "Notes")
        }
    }

    /// The search field's prompt, which names what is being searched (R6).
    var prompt: String {
        switch self {
        case .all: String(localized: "Name, vendor, registered name, attachment…")
        case .productName: String(localized: "Search product names")
        case .vendor: String(localized: "Search vendors")
        case .registeredName: String(localized: "Search registered names")
        case .attachmentName: String(localized: "Search attachment names")
        case .notes: String(localized: "Search notes")
        }
    }

    /// True when `license` matches `query` in this scope.
    ///
    /// Whole-query substring matching with `localizedStandardContains`, so case and diacritics are
    /// ignored and the query is never split into tokens (D11). `query` is already trimmed by the
    /// caller, which also handles the whitespace-only case.
    func matches(_ license: LicenseSummary, query: String) -> Bool {
        switch self {
        case .all:
            // The seven fields of R4. No serial, ever (R7).
            [
                license.productName, license.vendor, license.registeredName,
                license.registeredEmail, license.version, license.notes,
            ].contains { $0.localizedStandardContains(query) }
                || Self.attachmentName.matches(license, query: query)
        case .productName:
            license.productName.localizedStandardContains(query)
        case .vendor:
            license.vendor.localizedStandardContains(query)
        case .registeredName:
            license.registeredName.localizedStandardContains(query)
        case .attachmentName:
            license.attachments.contains { $0.fileName.localizedStandardContains(query) }
        case .notes:
            license.notes.localizedStandardContains(query)
        }
    }
}
