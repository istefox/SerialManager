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
