import Foundation

#if DEBUG

/// Obviously fake sample licenses for previews and tests. Never put real data here.
enum SampleData {
    static let reference = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    static let entries: [(LicenseSummary, String?)] = [
        entry("Acme Photo Studio", vendor: "Acme Software", version: "3.2",
              serial: "ACME-0000-TEST-0000", notes: "Sample entry for previews."),
        entry("Example Markdown Editor", vendor: "Example Corp", version: "1.0",
              serial: "EXAMPLE-1111-2222-3333"),
        entry("Fictional Backup Pro", vendor: "Nowhere Labs", version: "12",
              serial: nil),
        entry("Placeholder Video Converter", vendor: "Sample Inc.", version: "",
              serial: "FAKE-KEY-ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ00-0000"),
        entry("zeta Test Utility", vendor: "", version: "0.9",
              serial: "ZETA-0000"),
    ]

    static var licenses: [LicenseSummary] { entries.map(\.0) }

    static var first: LicenseSummary { entries[0].0 }

    /// The sample whose serial is missing from the (fake) Keychain.
    static var missingSerial: LicenseSummary { entries[2].0 }

    private static func entry(
        _ name: String, vendor: String, version: String, serial: String?, notes: String = ""
    ) -> (LicenseSummary, String?) {
        let license = LicenseSummary(
            id: UUID(),
            productName: name,
            vendor: vendor,
            registeredName: "Jane Appleseed",
            registeredEmail: "user@example.com",
            purchaseDate: reference,
            version: version,
            notes: notes,
            createdAt: reference,
            updatedAt: reference
        )
        return (license, serial)
    }
}
#endif
