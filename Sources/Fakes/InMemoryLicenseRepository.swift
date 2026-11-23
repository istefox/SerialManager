import Foundation

/// In-memory `LicenseRepository` for previews and tests. Not used in production.
actor InMemoryLicenseRepository: LicenseRepository {
    struct NotFound: Error {}

    private var licenses: [UUID: LicenseSummary] = [:]
    private var serials: [UUID: String] = [:]
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
        license.purchaseDate = draft.purchaseDate
        license.version = draft.version
        license.notes = draft.notes
        license.updatedAt = now()
        licenses[id] = license
        store(serial: draft.serial, for: id)
        return license
    }

    func delete(id: UUID) async throws {
        try check()
        licenses[id] = nil
        serials[id] = nil
    }

    func serial(for id: UUID) async throws -> String? {
        try check()
        return serials[id]
    }

    /// Same outcomes and serial rules as the SwiftData repository: `""` counts as no serial, a
    /// stored serial is never removed, `.skip` changes nothing.
    func importLicense(_ license: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome {
        try check()
        let outcome: LicenseImportOutcome
        switch (licenses[license.id] != nil, policy) {
        case (true, .skip): return .skipped
        case (true, .replace): outcome = .replaced
        case (false, _): outcome = .created
        }
        licenses[license.id] = license
        if let serial, !serial.isEmpty {
            serials[license.id] = serial
        }
        return outcome
    }

    private func store(serial: String, for id: UUID) {
        serials[id] = serial.isEmpty ? nil : serial
    }

    private func check() throws {
        if let failure { throw failure }
    }
}
