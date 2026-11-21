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
    private let fetchFailure: (any Error)?
    private(set) var serialReads: [UUID] = []

    /// A license without an entry in `serials` reads as `.missing`.
    init(
        licenses: [LicenseSummary] = [],
        serials: [UUID: SerialResult] = [:],
        fetchFailure: (any Error)? = nil
    ) {
        self.licenses = licenses
        self.serials = serials
        self.fetchFailure = fetchFailure
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
}
