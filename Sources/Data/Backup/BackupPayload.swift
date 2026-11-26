import Foundation

/// The JSON plaintext of a backup (docs/adr/0002-backup-format.md, section 6).
///
/// Every `LicenseSummary` field plus `serial`. Optionals are written as `null`, never omitted:
/// a synthesized `Encodable` would drop the key, and import treats a missing required key as a
/// corrupted file.
struct BackupPayload: Codable, Equatable, Sendable {
    /// One attachment inside a license entry, format version 2 (ADR 0002 section 6;
    /// SPEC 0018, R23).
    ///
    /// `byteCount` is the plaintext size the library recorded and `data` the plaintext itself,
    /// base64 encoded by `JSONEncoder`'s default `Data` strategy. The two must agree: a mismatch
    /// makes the file corrupted, so a truncated or padded blob is never imported as if it were
    /// whole.
    struct Attachment: Codable, Equatable, Sendable {
        let id: UUID
        let fileName: String
        /// UTType identifier when the library knew one. Written as `null`, never omitted.
        let contentType: String?
        let byteCount: Int
        let addedAt: Date
        let data: Data

        enum CodingKeys: String, CodingKey {
            case id, fileName, contentType, byteCount, addedAt, data
        }

        init(id: UUID, fileName: String, contentType: String?, byteCount: Int, addedAt: Date, data: Data) {
            self.id = id
            self.fileName = fileName
            self.contentType = contentType
            self.byteCount = byteCount
            self.addedAt = addedAt
            self.data = data
        }

        init(_ attachment: AttachmentSummary, data: Data) {
            self.init(
                id: attachment.id,
                fileName: attachment.fileName,
                contentType: attachment.contentType,
                byteCount: attachment.byteCount,
                addedAt: attachment.addedAt,
                data: data
            )
        }

        /// Every key must be present; `contentType` may be null but not missing, for the same
        /// reason `purchaseDate` may not be on an entry.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.contentType) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.contentType,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "Required key"))
            }
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                fileName: try container.decode(String.self, forKey: .fileName),
                contentType: try container.decodeIfPresent(String.self, forKey: .contentType),
                byteCount: try container.decode(Int.self, forKey: .byteCount),
                addedAt: try container.decode(Date.self, forKey: .addedAt),
                data: try container.decode(Data.self, forKey: .data)
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(fileName, forKey: .fileName)
            if let contentType {
                try container.encode(contentType, forKey: .contentType)
            } else {
                try container.encodeNil(forKey: .contentType)
            }
            try container.encode(byteCount, forKey: .byteCount)
            try container.encode(addedAt, forKey: .addedAt)
            try container.encode(data, forKey: .data)
        }

        /// The attachment as the repository takes it on import, bytes included.
        var imported: AttachmentImport {
            AttachmentImport(
                id: id, fileName: fileName, contentType: contentType, addedAt: addedAt, data: data)
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let productName: String
        let vendor: String
        /// Name of the person the license is registered to. Optional key, added after version 1 was
        /// first written: a backup without it decodes as `""` (ADR 0002, sections 6 and 7).
        let registeredName: String
        let registeredEmail: String
        /// Homepage of the product. Optional key, added after version 2 shipped: a backup without
        /// it decodes as `""`; export always writes it (ADR 0002, sections 6 and 7; SPEC 0030).
        let website: String
        let purchaseDate: Date?
        /// Product version string of the license, not the file format version.
        let version: String
        let notes: String
        let createdAt: Date
        let updatedAt: Date
        /// Nil when the Keychain item is missing or empty; never `""`.
        let serial: String?
        /// The license's attachments, version 2 onward (SPEC 0018, R23). Always written, `[]` when
        /// there is none. A version 1 file, or a version 2 entry without the key, decodes as `[]`.
        let attachments: [Attachment]

        enum CodingKeys: String, CodingKey {
            case id, productName, vendor, registeredName, registeredEmail, website, purchaseDate, version, notes
            case createdAt, updatedAt, serial, attachments
        }

        init(
            id: UUID,
            productName: String,
            vendor: String,
            registeredName: String,
            registeredEmail: String,
            website: String = "",
            purchaseDate: Date?,
            version: String,
            notes: String,
            createdAt: Date,
            updatedAt: Date,
            serial: String?,
            attachments: [Attachment] = []
        ) {
            self.id = id
            self.productName = productName
            self.vendor = vendor
            self.registeredName = registeredName
            self.registeredEmail = registeredEmail
            self.website = website
            self.purchaseDate = purchaseDate
            self.version = version
            self.notes = notes
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serial = serial
            self.attachments = attachments
        }

        /// Entry for `license`. An empty serial is stored as nil, as the ADR requires.
        init(_ license: LicenseSummary, serial: String?, attachments: [Attachment] = []) {
            self.init(
                id: license.id,
                productName: license.productName,
                vendor: license.vendor,
                registeredName: license.registeredName,
                registeredEmail: license.registeredEmail,
                website: license.website,
                purchaseDate: license.purchaseDate,
                version: license.version,
                notes: license.notes,
                createdAt: license.createdAt,
                updatedAt: license.updatedAt,
                serial: (serial?.isEmpty ?? true) ? nil : serial,
                attachments: attachments
            )
        }

        /// Every key of ADR 0002 section 6 must be present: `purchaseDate` and `serial` may be null
        /// but not missing (a synthesized decoder would accept a missing optional key, plan 0010 F6).
        /// Unknown keys are ignored. `serial` is kept as read: `""` stays `""` here and counts as no
        /// serial when the import is applied. `registeredName` is the one optional-by-absence key: it was
        /// added after version 1 shipped, so a file written without it decodes as `""` instead of failing
        /// (ADR 0002, section 7).
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            for key in [CodingKeys.purchaseDate, .serial] where !container.contains(key) {
                throw DecodingError.keyNotFound(
                    key, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Required key"))
            }
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                productName: try container.decode(String.self, forKey: .productName),
                vendor: try container.decode(String.self, forKey: .vendor),
                registeredName: try container.decodeIfPresent(String.self, forKey: .registeredName) ?? "",
                registeredEmail: try container.decode(String.self, forKey: .registeredEmail),
                website: try container.decodeIfPresent(String.self, forKey: .website) ?? "",
                purchaseDate: try container.decodeIfPresent(Date.self, forKey: .purchaseDate),
                version: try container.decode(String.self, forKey: .version),
                notes: try container.decode(String.self, forKey: .notes),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                updatedAt: try container.decode(Date.self, forKey: .updatedAt),
                serial: try container.decodeIfPresent(String.self, forKey: .serial),
                // Optional by absence, like `registeredName`: a version 1 file has no such key
                // (SPEC 0018, R23).
                attachments: try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(productName, forKey: .productName)
            try container.encode(vendor, forKey: .vendor)
            try container.encode(registeredName, forKey: .registeredName)
            try container.encode(registeredEmail, forKey: .registeredEmail)
            try container.encode(website, forKey: .website)
            if let purchaseDate {
                try container.encode(purchaseDate, forKey: .purchaseDate)
            } else {
                try container.encodeNil(forKey: .purchaseDate)
            }
            try container.encode(version, forKey: .version)
            try container.encode(notes, forKey: .notes)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            if let serial {
                try container.encode(serial, forKey: .serial)
            } else {
                try container.encodeNil(forKey: .serial)
            }
            try container.encode(attachments, forKey: .attachments)
        }
    }

    let exportedAt: Date
    let licenses: [Entry]

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Encoder of the export: sorted keys (stable bytes) and three-digit UTC dates.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Slashes stay literal: Base64 carries up to one `/` per 6 bits, and the optional `\/`
        // escape would double those bytes and push a library that is within every attachment
        // limit over the file-size cap (SPEC 0018, R24). `\/` remains valid on import.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC, the form without fractional seconds.
    static let wholeSecondDateStyle = Date.ISO8601FormatStyle()

    /// Decoder of a backup payload. Accepts exactly the two date forms of ADR 0002 section 6:
    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` (written by `makeEncoder()`) and the same without fractional
    /// seconds. Other digit counts and UTC offsets are rejected, although Foundation would parse
    /// some of them (plan 0010, F7 and P1).
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            switch dateShape(of: text) {
            case .fractional:
                return try Date(text, strategy: dateStyle)
            case .wholeSeconds:
                return try Date(text, strategy: wholeSecondDateStyle)
            case nil:
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Date not in a form of ADR 0002 section 6")
            }
        }
        return decoder
    }

    enum DateShape: Equatable {
        /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, 24 characters.
        case fractional
        /// `yyyy-MM-dd'T'HH:mm:ss'Z'`, 20 characters.
        case wholeSeconds
    }

    /// Which accepted form `text` has, by position only (ASCII digits and separators); nil for any
    /// other text. The calendar values are checked by the parse that follows.
    static func dateShape(of text: String) -> DateShape? {
        let bytes = Array(text.utf8)
        let pattern: String
        let shape: DateShape
        switch bytes.count {
        case 24:
            pattern = "dddd-dd-ddTdd:dd:dd.dddZ"
            shape = .fractional
        case 20:
            pattern = "dddd-dd-ddTdd:dd:ddZ"
            shape = .wholeSeconds
        default:
            return nil
        }
        for (byte, expected) in zip(bytes, pattern.utf8) {
            let matches = expected == UInt8(ascii: "d") ? (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) : byte == expected
            if !matches { return nil }
        }
        return shape
    }

    /// Decodes and validates the plaintext of an import (ADR 0002 section 5, step 6). Pure, no I/O.
    ///
    /// Not UTF-8, not valid JSON for this version, a missing required key, a wrong type, an invalid
    /// UUID or date, two licenses with the same `id`, or a blank product name (SPEC 0010, D2) give
    /// `BackupError.corruptedFile`. The product name uses the model's own rule, so a payload that
    /// passes here cannot be refused by `License` when it is applied.
    ///
    /// The same holds for an attachment (SPEC 0018, R23): base64 that does not decode is already a
    /// decoding failure, and a decoded length that disagrees with `byteCount`, a blank file name, a
    /// negative `byteCount`, or the same attachment id twice in the file are all corrupted. Ids are
    /// unique across the whole file, not per license: one id is one file on disk.
    static func decodeForImport(_ plaintext: Data) throws(BackupError) -> BackupPayload {
        guard String(data: plaintext, encoding: .utf8) != nil else { throw .corruptedFile }
        let payload: BackupPayload
        do {
            payload = try makeDecoder().decode(BackupPayload.self, from: plaintext)
        } catch {
            throw .corruptedFile
        }
        var ids = Set<UUID>()
        var attachmentIDs = Set<UUID>()
        for entry in payload.licenses {
            guard ids.insert(entry.id).inserted, License.isValidProductName(entry.productName) else {
                throw .corruptedFile
            }
            for attachment in entry.attachments {
                guard attachmentIDs.insert(attachment.id).inserted,
                      AttachmentRecord.isValidFileName(attachment.fileName),
                      attachment.byteCount >= 0,
                      attachment.data.count == attachment.byteCount
                else {
                    throw .corruptedFile
                }
            }
        }
        return payload
    }
}
