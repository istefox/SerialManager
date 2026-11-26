import Foundation

/// In-memory `LicenseRepository` for previews and tests. Not used in production.
actor InMemoryLicenseRepository: LicenseRepository {
    struct NotFound: Error {}

    private var licenses: [UUID: LicenseSummary] = [:]
    private var serials: [UUID: String] = [:]
    /// Plaintext bytes per attachment id. In memory and in the clear on purpose: this fake is for
    /// previews and tests, never for production (SPEC 0018, R28).
    private var attachmentData: [UUID: Data] = [:]
    private var failure: (any Error)?
    private let now: @Sendable () -> Date

    init(
        entries: [(LicenseSummary, String?)] = [],
        failure: (any Error)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        for (license, serial) in entries {
            licenses[license.id] = license
            serials[license.id] = serial
        }
        self.failure = failure
        self.now = now
    }

    #if DEBUG
    static func sample() -> InMemoryLicenseRepository {
        InMemoryLicenseRepository(entries: SampleData.entries)
    }
    #endif

    func setFailure(_ error: (any Error)?) { failure = error }

    func fetchAll() async throws -> [LicenseSummary] {
        try check()
        return Array(licenses.values)
    }

    func create(_ draft: LicenseDraft) async throws -> LicenseSummary {
        try check()
        let date = now()
        let license = LicenseSummary(
            id: UUID(),
            productName: draft.productName,
            vendor: draft.vendor,
            registeredName: draft.registeredName,
            registeredEmail: draft.registeredEmail,
            website: draft.website,
            purchaseDate: draft.purchaseDate,
            version: draft.version,
            notes: draft.notes,
            createdAt: date,
            updatedAt: date
        )
        licenses[license.id] = license
        store(serial: draft.serial, for: license.id)
        return license
    }

    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary {
        try check()
        guard var license = licenses[id] else { throw NotFound() }
        license.productName = draft.productName
        license.vendor = draft.vendor
        license.registeredName = draft.registeredName
        license.registeredEmail = draft.registeredEmail
        license.website = draft.website
        license.purchaseDate = draft.purchaseDate
        license.version = draft.version
        license.notes = draft.notes
        license.updatedAt = now()
        licenses[id] = license
        if !draft.leavesSerialUntouched { store(serial: draft.serial, for: id) }
        return license
    }

    func delete(id: UUID) async throws {
        try check()
        for attachment in licenses[id]?.attachments ?? [] { attachmentData[attachment.id] = nil }
        licenses[id] = nil
        serials[id] = nil
    }

    func serial(for id: UUID) async throws -> String? {
        try check()
        return serials[id]
    }

    /// Same outcomes and serial rules as the SwiftData repository: `""` counts as no serial, a
    /// stored serial is never removed, `.skip` changes nothing.
    func importLicense(
        _ license: LicenseSummary,
        serial: String?,
        attachments: [AttachmentImport],
        policy: ConflictPolicy
    ) async throws -> LicenseImportOutcome {
        try check()
        let local = licenses[license.id]
        let outcome: LicenseImportOutcome
        switch (local != nil, policy) {
        case (true, .skip): return .skipped
        case (true, .replace): outcome = .replaced
        case (false, _): outcome = .created
        }
        // Merge by id, never delete, no limit, and the dates stay as the backup wrote them (D12).
        var merged = local?.attachments ?? []
        let known = Set(merged.map(\.id))
        for attachment in attachments where !known.contains(attachment.id) {
            merged.append(AttachmentSummary(
                id: attachment.id,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount,
                contentType: attachment.contentType,
                addedAt: attachment.addedAt
            ))
            attachmentData[attachment.id] = attachment.data
        }
        var stored = license
        stored.attachments = merged.sorted(by: Self.isOrderedBefore)
        licenses[license.id] = stored
        if let serial, !serial.isEmpty {
            serials[license.id] = serial
        }
        return outcome
    }

    func addAttachment(_ file: AttachmentFile, to licenseID: UUID) async throws -> LicenseSummary {
        try check()
        guard AttachmentRecord.isValidFileName(file.fileName) else {
            throw AttachmentValidationError.emptyFileName
        }
        guard var license = licenses[licenseID] else { throw NotFound() }
        try AttachmentLimits.check(
            byteCount: file.byteCount,
            fileName: file.fileName,
            licenseBytes: license.attachmentBytes,
            libraryBytes: licenses.values.reduce(0) { $0 + $1.attachmentBytes }
        )
        let summary = AttachmentSummary(
            id: UUID(),
            fileName: file.fileName,
            byteCount: file.byteCount,
            contentType: file.contentType,
            addedAt: now()
        )
        attachmentData[summary.id] = file.data
        license.attachments = (license.attachments + [summary]).sorted(by: Self.isOrderedBefore)
        license.updatedAt = now()
        licenses[licenseID] = license
        return license
    }

    func removeAttachment(id: UUID) async throws -> LicenseSummary {
        try check()
        guard var license = licenses.values.first(where: { $0.attachments.contains(where: { $0.id == id }) })
        else { throw AttachmentError.notFound(id) }
        license.attachments.removeAll { $0.id == id }
        license.updatedAt = now()
        licenses[license.id] = license
        attachmentData[id] = nil
        return license
    }

    func attachmentIsReadable(id: UUID) async -> Bool {
        attachmentData[id] != nil
    }

    func attachmentData(id: UUID) async throws -> Data {
        try check()
        guard let data = attachmentData[id] else { throw AttachmentError.fileMissing(id) }
        return data
    }

    /// Same order as the real repository: `addedAt`, then the file name, then the id.
    private static func isOrderedBefore(_ lhs: AttachmentSummary, _ rhs: AttachmentSummary) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        switch lhs.fileName.localizedStandardCompare(rhs.fileName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func store(serial: String, for id: UUID) {
        serials[id] = serial.isEmpty ? nil : serial
    }

    private func check() throws {
        if let failure { throw failure }
    }
}
