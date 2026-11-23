import Foundation
@testable import SerialManager

/// Read-only `LicenseRepository` for the export tests (plan 0009, F8). Never touches the Keychain.
///
/// Holds a fixed list of licenses and a scripted serial result per license id, so a test can
/// produce an item holding `""` or a Keychain failure for one license only. Write operations are
/// not used by the export and fail.
actor ScriptedLicenseRepository: LicenseRepository {
    enum SerialResult: Sendable {
        case value(String)
        case missing
        case failure(any Error)
    }

    struct Unsupported: Error {}

    private let licenses: [LicenseSummary]
    private let serials: [UUID: SerialResult]
    /// Plaintext per attachment id, so the export tests can seal real bytes. Fake data only.
    private let attachments: [UUID: Data]
    private let attachmentFailures: Set<UUID>
    private let fetchFailure: (any Error)?
    private(set) var serialReads: [UUID] = []
    private(set) var attachmentReads: [UUID] = []

    /// A license without an entry in `serials` reads as `.missing`.
    init(
        licenses: [LicenseSummary] = [],
        serials: [UUID: SerialResult] = [:],
        attachments: [UUID: Data] = [:],
        attachmentFailures: Set<UUID> = [],
        fetchFailure: (any Error)? = nil
    ) {
        self.licenses = licenses
        self.serials = serials
        self.attachments = attachments
        self.attachmentFailures = attachmentFailures
        self.fetchFailure = fetchFailure
    }

    func attachmentIsReadable(id: UUID) async -> Bool {
        attachments[id] != nil && !attachmentFailures.contains(id)
    }

    func attachmentData(id: UUID) async throws -> Data {
        attachmentReads.append(id)
        if attachmentFailures.contains(id) { throw AttachmentError.fileMissing(id) }
        guard let data = attachments[id] else { throw AttachmentError.notFound(id) }
        return data
    }

    func fetchAll() async throws -> [LicenseSummary] {
        if let fetchFailure { throw fetchFailure }
        return licenses
    }

    func serial(for id: UUID) async throws -> String? {
        serialReads.append(id)
        switch serials[id] ?? .missing {
        case .value(let serial): return serial
        case .missing: return nil
        case .failure(let error): throw error
        }
    }

    func create(_ draft: LicenseDraft) async throws -> LicenseSummary { throw Unsupported() }
    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary { throw Unsupported() }
    func delete(id: UUID) async throws { throw Unsupported() }
    func importLicense(
        _ license: LicenseSummary, serial: String?, attachments: [AttachmentImport],
        policy: ConflictPolicy
    ) async throws -> LicenseImportOutcome { throw Unsupported() }
    func addAttachment(_ file: AttachmentFile, to licenseID: UUID) async throws -> LicenseSummary {
        throw Unsupported()
    }
    func removeAttachment(id: UUID) async throws -> LicenseSummary { throw Unsupported() }
}
