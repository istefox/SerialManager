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
        entry("Sample Font Manager", vendor: "Typeface Example", version: "2.1",
              serial: "SAMPLE-FONT-0000", attachments: [
                  ("Licence.lic", "public.data", 2_048),
                  ("Invoice-sample.pdf", "com.adobe.pdf", 184_320),
              ]),
    ]

    static var licenses: [LicenseSummary] { entries.map(\.0) }

    static var first: LicenseSummary { entries[0].0 }

    /// The sample whose serial is missing from the (fake) Keychain.
    static var missingSerial: LicenseSummary { entries[2].0 }

    /// The sample carrying attachments, for the form and detail previews (SPEC 0018, R28). The
    /// file names are obviously fake and no preview holds their bytes.
    static var withAttachments: LicenseSummary { entries[5].0 }

    private static func entry(
        _ name: String, vendor: String, version: String, serial: String?, notes: String = "",
        attachments: [(String, String?, Int)] = []
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
            updatedAt: reference,
            attachments: attachments.enumerated().map { offset, file in
                AttachmentSummary(
                    id: UUID(), fileName: file.0, byteCount: file.2, contentType: file.1,
                    addedAt: reference.addingTimeInterval(Double(offset)))
            }
        )
        return (license, serial)
    }
}
#endif
