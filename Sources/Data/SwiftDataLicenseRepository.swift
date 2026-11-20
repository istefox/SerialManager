import Foundation
import SwiftData

/// Failures raised by the repository itself. Serial store and SwiftData errors are never
/// wrapped in this type: they are rethrown as they are, so the GUI sees them unchanged.
enum LicenseRepositoryError: Error, Equatable {
    /// No entry exists for this id.
    case notFound(UUID)
    /// `create` generated an id that an existing entry already uses; nothing was written.
    case duplicateID(UUID)
    /// The persistent library could not be opened at launch.
    case libraryUnavailable
}

/// `LicenseRepository` backed by SwiftData for the metadata and a `SerialStore` for the serial
/// (ADR 0001, SPEC `docs/specs/0004-license-repository.md`, plan section 2).
///
/// The only code that creates, updates and deletes entries. Three invariants keep the entry and
/// its serial consistent:
/// - I1: no unsaved SwiftData change is held across an `await`. Each mutation does its serial
///   store work first, then mutates the context, persists and (on failure) rolls back with no
///   suspension in between. Compensating serial store calls run only after `rollback()`.
/// - I2: the entry is fetched again after every `await`, never reused from before it.
/// - I3: mutations run one at a time, behind a FIFO lock shared by every id.
///
/// Errors are never wrapped. When a compensating step fails, the original error is thrown and the
/// residue (orphan or stale serial) stays: no clean-up sweep runs (D3, R12).
///
/// Conforms to `ModelActor` explicitly rather than through the macro, because the macro's generated
/// init does not combine with the stored properties below (plan P11). The protocol extension derives
/// `unownedExecutor` and `modelContext` from `modelExecutor`.
actor SwiftDataLicenseRepository: LicenseRepository, ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private let serials: any SerialStore
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let beforeSave: @Sendable () throws -> Void

    /// Mutation lock (I3). A Keychain call that never returns (a system prompt left open) blocks
    /// every later mutation until it does; reads do not take the lock and keep working. Accepted:
    /// mutations are user-driven and rare.
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Number of mutations waiting for the lock. For the I3 test only.
    var pendingMutationCount: Int { mutationWaiters.count }

    /// - Parameters:
    ///   - makeID: id source for `create`; tests inject a fixed id to force a collision.
    ///   - now: clock for `createdAt` and `updatedAt`.
    ///   - beforeSave: runs before every `save()`; tests make it throw to force a persist failure.
    init(
        modelContainer: ModelContainer,
        serials: any SerialStore,
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() },
        beforeSave: @escaping @Sendable () throws -> Void = {}
    ) {
        let context = ModelContext(modelContainer)
        // Only `persist()` saves, so `rollback()` always sees the pending change.
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.serials = serials
        self.makeID = makeID
        self.now = now
        self.beforeSave = beforeSave
    }

    // MARK: Reads (no lock: by I1 the context holds committed state only across suspensions)

    func fetchAll() async throws -> [LicenseSummary] {
        try modelContext.fetch(FetchDescriptor<License>()).map(LicenseSummary.init)
    }

    func serial(for id: UUID) async throws -> String? {
        try await serials.serial(for: id)
    }

    // MARK: Mutations

    func create(_ draft: LicenseDraft) async throws -> LicenseSummary {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        let id = makeID()
        // Validates the product name before any write (R5).
        let license = try License(
            id: id,
            productName: draft.productName,
            vendor: draft.vendor,
            registeredEmail: draft.registeredEmail,
            purchaseDate: draft.purchaseDate,
            version: draft.version,
            notes: draft.notes,
            createdAt: now()
        )

        // D5: an insert with an existing id is a silent upsert in SwiftData, so look it up first.
        // There is an `await` between this check and the insert; I3 keeps every other mutation out
        // of that window, and the check runs before the only serial store write.
        guard try fetchLicense(id) == nil else { throw LicenseRepositoryError.duplicateID(id) }

        // An empty serial is valid and has no item (D7).
        let savedSerial = !draft.serial.isEmpty
        if savedSerial {
            try await serials.save(draft.serial, for: id)
        }

        do {
            modelContext.insert(license)
            try persist()
        } catch {
            modelContext.rollback()
            if savedSerial {
                // If this fails, an orphan serial remains under `id` (R12, D3).
                try? await serials.deleteSerial(for: id)
            }
            throw error
        }
        return LicenseSummary(license)
    }

    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        // Same rule as `License.validate`, so `License.update` cannot throw for it later (R5).
        guard draft.hasValidProductName else { throw LicenseValidationError.emptyProductName }
        guard try fetchLicense(id) != nil else { throw LicenseRepositoryError.notFound(id) }

        let old = try await readPreviousSerial(for: id)
        let wroteSerial = try await applySerial(draft.serial, over: old, for: id)

        // I2: fetch again after the serial store step.
        let found: License?
        do {
            found = try fetchLicense(id)
        } catch {
            if wroteSerial { await restoreSerial(old, for: id) }
            throw error
        }
        guard let license = found else {
            // Defensive: unreachable under I3. Remove what this call wrote so no orphan is left;
            // if that fails, an orphan serial remains (R12).
            if wroteSerial { try? await serials.deleteSerial(for: id) }
            throw LicenseRepositoryError.notFound(id)
        }

        do {
            try license.update(
                productName: draft.productName,
                vendor: draft.vendor,
                registeredEmail: draft.registeredEmail,
                purchaseDate: draft.purchaseDate,
                version: draft.version,
                notes: draft.notes,
                now: now()
            )
            try persist()
        } catch {
            modelContext.rollback()
            if wroteSerial { await restoreSerial(old, for: id) }
            throw error
        }
        return LicenseSummary(license)
    }

    func delete(id: UUID) async throws {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        let old = try await readPreviousSerial(for: id)
        // Serial first (D1): if this fails, the entry is not touched. Runs for an unknown id too (R10).
        try await serials.deleteSerial(for: id)

        do {
            guard let license = try fetchLicense(id) else { return }
            modelContext.delete(license)
            try persist()
        } catch {
            modelContext.rollback()
            switch old {
            case .value(let serial):
                // If this fails, the entry stays without its serial (R12, D3).
                try? await serials.save(serial, for: id)
            case .absent:
                break
            case .unreadable:
                // The previous value could not be read, so it cannot be restored: the entry stays
                // and its item stays deleted (D9, R12).
                break
            }
            throw error
        }
    }

    // MARK: Helpers

    /// What the serial store held before a change. Unreadable is kept apart from absent (D9).
    private enum PreviousSerial {
        case absent
        case value(String)
        case unreadable
    }

    /// `.undecodableData` does not block the change (D9); every other read error stops it before any
    /// write.
    private func readPreviousSerial(for id: UUID) async throws -> PreviousSerial {
        do {
            if let serial = try await serials.serial(for: id) { return .value(serial) }
            return .absent
        } catch SerialStoreError.undecodableData {
            return .unreadable
        }
    }

    /// Brings the serial store from `old` to `serial` (an empty serial deletes the item, D6).
    /// Returns true when it wrote or deleted something.
    private func applySerial(_ serial: String, over old: PreviousSerial, for id: UUID) async throws -> Bool {
        switch (old, serial.isEmpty) {
        case (.absent, true):
            return false
        case (.value(let current), false) where current == serial:
            return false
        case (.value, true), (.unreadable, true):
            try await serials.deleteSerial(for: id)
            return true
        case (.absent, false), (.value, false), (.unreadable, false):
            try await serials.save(serial, for: id)
            return true
        }
    }

    /// Compensation for `update`: puts the serial store back to `old`. Errors are discarded; the
    /// caller throws the original error (R12, D3).
    private func restoreSerial(_ old: PreviousSerial, for id: UUID) async {
        switch old {
        case .absent:
            // If this fails, an orphan or stale serial remains under `id`.
            try? await serials.deleteSerial(for: id)
        case .value(let serial):
            // If this fails, the entry keeps its old fields with the new (or no) serial.
            try? await serials.save(serial, for: id)
        case .unreadable:
            // The previous value is unknown: the new state stays (D9).
            break
        }
    }

    private func fetchLicense(_ id: UUID) throws -> License? {
        var descriptor = FetchDescriptor<License>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func persist() throws {
        try beforeSave()
        try modelContext.save()
    }

    private func acquireMutationLock() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    /// Hands the lock to the first waiter, if any, without releasing it in between (FIFO).
    private func releaseMutationLock() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}

private extension LicenseSummary {
    init(_ license: License) {
        self.init(
            id: license.id,
            productName: license.productName,
            vendor: license.vendor,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            createdAt: license.createdAt,
            updatedAt: license.updatedAt
        )
    }
}
