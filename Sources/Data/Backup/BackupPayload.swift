import Foundation

/// The JSON plaintext of a backup (docs/adr/0002-backup-format.md, section 6).
///
/// Every `LicenseSummary` field plus `serial`. Optionals are written as `null`, never omitted:
/// a synthesized `Encodable` would drop the key, and import treats a missing required key as a
/// corrupted file.
struct BackupPayload: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let productName: String
        let vendor: String
        let registeredEmail: String
        let purchaseDate: Date?
        /// Product version string of the license, not the file format version.
        let version: String
        let notes: String
        let createdAt: Date
        let updatedAt: Date
        /// Nil when the Keychain item is missing or empty; never `""`.
        let serial: String?

        enum CodingKeys: String, CodingKey {
            case id, productName, vendor, registeredEmail, purchaseDate, version, notes
            case createdAt, updatedAt, serial
        }

        init(
            id: UUID,
            productName: String,
            vendor: String,
            registeredEmail: String,
            purchaseDate: Date?,
            version: String,
            notes: String,
            createdAt: Date,
            updatedAt: Date,
            serial: String?
        ) {
            self.id = id
            self.productName = productName
            self.vendor = vendor
            self.registeredEmail = registeredEmail
            self.purchaseDate = purchaseDate
            self.version = version
            self.notes = notes
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serial = serial
        }

        /// Entry for `license`. An empty serial is stored as nil, as the ADR requires.
        init(_ license: LicenseSummary, serial: String?) {
            self.init(
                id: license.id,
                productName: license.productName,
                vendor: license.vendor,
                registeredEmail: license.registeredEmail,
                purchaseDate: license.purchaseDate,
                version: license.version,
                notes: license.notes,
                createdAt: license.createdAt,
                updatedAt: license.updatedAt,
                serial: (serial?.isEmpty ?? true) ? nil : serial
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(productName, forKey: .productName)
            try container.encode(vendor, forKey: .vendor)
            try container.encode(registeredEmail, forKey: .registeredEmail)
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
        }
    }

    let exportedAt: Date
    let licenses: [Entry]

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Encoder of the export: sorted keys (stable bytes) and three-digit UTC dates.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    /// Decoder for the three-digit form written by `makeEncoder()`. Import (#10) widens it to the
    /// form without fractional seconds and adds payload validation.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            return try Date(text, strategy: dateStyle)
        }
        return decoder
    }
}
