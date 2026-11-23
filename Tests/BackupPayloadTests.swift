import Foundation
import Testing
@testable import SerialManager

/// JSON payload of the backup (ADR 0002, section 6): date form, sorted keys, explicit nulls.
struct BackupPayloadTests {
    private typealias F = BackupFixtures

    private func json(_ payload: BackupPayload) throws -> String {
        String(decoding: try BackupPayload.makeEncoder().encode(payload), as: UTF8.self)
    }

    @Test func datesAreUTCWithThreeFractionalDigits() throws {
        let payload = BackupPayload(exportedAt: Date(timeIntervalSince1970: 1.5), licenses: [])
        #expect(try json(payload) == #"{"exportedAt":"1970-01-01T00:00:01.500Z","licenses":[]}"#)

        let whole = BackupPayload(exportedAt: Date(timeIntervalSince1970: 1_767_225_600), licenses: [])
        #expect(try json(whole).contains(#""exportedAt":"2026-01-01T00:00:00.000Z""#))
    }

    @Test func entryKeysAreSortedAndNullsAreExplicit() throws {
        let payload = BackupPayload(exportedAt: F.exportedAt, licenses: [BackupPayload.Entry(F.editor, serial: nil)])
        let expected = #"{"exportedAt":"2026-01-01T10:00:00.750Z","licenses":[{"#
            + #""createdAt":"2026-01-01T09:00:00.250Z","#
            + #""id":"00000000-0000-4000-8000-000000000001","#
            + #""notes":"","#
            + #""productName":"Sample Editor","#
            + #""purchaseDate":null,"#
            + #""registeredEmail":"user@example.com","#
            + #""registeredName":"","#
            + #""serial":null,"#
            + #""updatedAt":"2026-01-01T09:00:00.500Z","#
            + #""vendor":"Example Software","#
            + #""version":"1.0"}]}"#
        #expect(try json(payload) == expected)
    }

    @Test func versionIsTheProductVersionString() throws {
        let payload = BackupPayload(exportedAt: F.exportedAt, licenses: [BackupPayload.Entry(F.viewer, serial: nil)])
        #expect(try json(payload).contains(#""version":"2.5""#))
    }

    @Test(arguments: [nil, ""] as [String?])
    func missingOrEmptySerialBecomesNil(_ serial: String?) {
        #expect(BackupPayload.Entry(F.editor, serial: serial).serial == nil)
    }

    @Test func serialIsKeptVerbatim() {
        #expect(BackupPayload.Entry(F.editor, serial: " FAKE-0000 ").serial == " FAKE-0000 ")
    }

    @Test func decoderReadsWhatTheEncoderWrites() throws {
        let payload = BackupPayload(exportedAt: F.exportedAt, licenses: [
            BackupPayload.Entry(F.editor, serial: F.editorSerial),
            BackupPayload.Entry(F.viewer, serial: nil),
        ])
        let data = try BackupPayload.makeEncoder().encode(payload)
        #expect(try BackupPayload.makeDecoder().decode(BackupPayload.self, from: data) == payload)
    }
}

/// Import decoding and validation (plan 0010, 2.4; ADR 0002 section 6). Pure, no file.
struct BackupPayloadImportTests {
    private typealias J = BackupPayloadJSON

    private func decode(_ data: Data) -> Result<BackupPayload, BackupError> {
        Result { () throws(BackupError) in try BackupPayload.decodeForImport(data) }
    }

    private func entry(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var entry = J.entry()
        change(&entry)
        return entry
    }

    /// `registeredName` was added after version 1 shipped, so a file written without it must still
    /// import, with the name empty (ADR 0002 sections 6 and 7; ticket #17).
    @Test func payloadWithoutRegisteredNameDecodesWithAnEmptyName() throws {
        let data = try J.payload(entries: [entry { $0.removeValue(forKey: "registeredName") }])
        let payload = try decode(data).get()
        #expect(payload.licenses.map(\.registeredName) == [""])
    }

    @Test func registeredNameDecodesWhenPresent() throws {
        let data = try J.payload(entries: [entry { $0["registeredName"] = "Jane Appleseed" }])
        let payload = try decode(data).get()
        #expect(payload.licenses.map(\.registeredName) == ["Jane Appleseed"])
    }

    @Test func validPayloadDecodes() throws {
        let payload = try decode(try J.payload(entries: [J.entry(), J.entry(id: J.viewerID, name: "Sample Viewer")])).get()
        #expect(payload.licenses.map(\.productName) == ["Sample Editor", "Sample Viewer"])
        #expect(payload.licenses.first?.serial == "FAKE-0000-0000-0000")
        #expect(payload.licenses.first?.purchaseDate == nil)
    }

    enum Invalid: String, CaseIterable, CustomTestStringConvertible {
        case duplicateID, missingCreatedAt, missingSerial, missingPurchaseDate, badUUID, blankName
        case notJSON, notUTF8, licensesNotAnArray

        var testDescription: String { rawValue }
    }

    @Test(arguments: Invalid.allCases)
    func invalidPayloadIsCorrupted(_ invalid: Invalid) throws {
        let data: Data
        switch invalid {
        case .duplicateID:
            data = try J.payload(entries: [J.entry(), J.entry(name: "Sample Viewer")])
        case .missingCreatedAt:
            data = try J.payload(entries: [entry { $0["createdAt"] = nil }])
        case .missingSerial:
            data = try J.payload(entries: [entry { $0["serial"] = nil }])
        case .missingPurchaseDate:
            data = try J.payload(entries: [entry { $0["purchaseDate"] = nil }])
        case .badUUID:
            data = try J.payload(entries: [J.entry(id: "not-a-uuid")])
        case .blankName:
            data = try J.payload(entries: [J.entry(name: "   ")])
        case .notJSON:
            data = Data("exportedAt licenses".utf8)
        case .notUTF8:
            data = Data([0x7B, 0xC3, 0x28, 0x7D])
        case .licensesNotAnArray:
            data = try J.payload(J.entry() as Any)
        }
        #expect(decode(data) == .failure(.corruptedFile))
    }

    @Test func unknownKeysAreIgnored() throws {
        let data = try J.payload(entries: [entry { $0["color"] = "red" }])
        #expect(try decode(data).get().licenses.count == 1)
    }

    @Test func emptySerialIsKeptAsRead() throws {
        let data = try J.payload(entries: [entry { $0["serial"] = "" }, entry {
            $0["id"] = J.viewerID
            $0["serial"] = NSNull()
        }])
        #expect(try decode(data).get().licenses.map(\.serial) == ["", nil])
    }

    @Test func emptyLibraryDecodes() throws {
        #expect(try decode(try J.payload(entries: [])).get().licenses.isEmpty)
    }

    // MARK: Dates (P1)

    @Test(arguments: [
        ("2026-01-01T09:00:00.250Z", 1_767_258_000.250),
        ("2026-01-01T09:00:00Z", 1_767_258_000),
    ] as [(String, TimeInterval)])
    func acceptedDateForms(_ text: String, _ seconds: TimeInterval) throws {
        let data = try J.payload(entries: [entry { $0["createdAt"] = text }])
        #expect(try decode(data).get().licenses.first?.createdAt == Date(timeIntervalSince1970: seconds))
    }

    @Test(arguments: [
        "2026-01-01T09:00:00.25Z",
        "2026-01-01T09:00:00.250123Z",
        "2026-01-01T09:00:00.250+01:00",
        "2026-01-01T09:00:00+01:00",
        "2026-13-01T09:00:00.250Z",
        "2026-01-01 09:00:00.250Z",
        "",
    ])
    func rejectedDateForms(_ text: String) throws {
        let data = try J.payload(entries: [entry { $0["updatedAt"] = text }])
        #expect(decode(data) == .failure(.corruptedFile))
    }

    @Test func rejectedExportDateMakesThePayloadCorrupted() throws {
        let data = try J.payload([[String: Any]](), exportedAt: "2026-01-01T10:00:00.75Z")
        #expect(decode(data) == .failure(.corruptedFile))
    }

    @Test func dateShapeIsCheckedByPosition() {
        #expect(BackupPayload.dateShape(of: "2026-01-01T09:00:00.250Z") == .fractional)
        #expect(BackupPayload.dateShape(of: "2026-01-01T09:00:00Z") == .wholeSeconds)
        #expect(BackupPayload.dateShape(of: "2026-01-01T09:00:00.25Z") == nil)
        #expect(BackupPayload.dateShape(of: "2026-01-01t09:00:00Z") == nil)
        #expect(BackupPayload.dateShape(of: "２026-01-01T09:00:00Z") == nil)
    }
}
