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
            registeredName: draft.registeredName,
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
                registeredName: draft.registeredName,
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

    // MARK: Import

    /// Writes one license of a backup (plan 0010, 2.3). See `LicenseRepository.importLicense`.
    ///
    /// Runs under the mutation lock (I3), so no other mutation slips between the id lookup and the
    /// write, and the SwiftData upsert on `@Attribute(.unique)` is never what decides a conflict.
    /// The serial rules are its own: `applySerial` and `restoreSerial` are not reused, because an
    /// import never removes a Keychain item that existed before the call (plan 0010, F4).
    func importLicense(_ record: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        // Same rule as `License.validate`, checked before any write in both branches.
        guard License.isValidProductName(record.productName) else {
            throw LicenseValidationError.emptyProductName
        }
        // `""` counts as no serial (ADR 0002).
        let wanted = serial.flatMap { $0.isEmpty ? nil : $0 }

        let exists = try fetchLicense(record.id) != nil
        switch (exists, policy) {
        case (true, .skip):
            // No serial store call and no context change.
            return .skipped
        case (true, .replace):
            try await replaceImported(record, serial: wanted)
            return .replaced
        case (false, _):
            try await createImported(record, serial: wanted)
            return .created
        }
    }

    /// Create branch: the id has no license.
    ///
    /// With no serial in the file, an orphan item already stored under this id stays in place and the
    /// new license shows it. Accepted edge (plan 0010, 2.3): an import never removes an item it did not
    /// create.
    private func createImported(_ record: LicenseSummary, serial wanted: String?) async throws {
        let id = record.id
        // Built before any write: validation cannot fail after the serial step.
        let license = try License(
            id: id,
            productName: record.productName,
            vendor: record.vendor,
            registeredName: record.registeredName,
            registeredEmail: record.registeredEmail,
            purchaseDate: record.purchaseDate,
            version: record.version,
            notes: record.notes,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )

        let written = try await writeImportedSerial(wanted, for: id)

        // I2: look the id up again after the serial store step (defensive under I3).
        let found: License?
        do {
            found = try fetchLicense(id)
        } catch {
            await undoImportedSerial(written, for: id)
            throw error
        }
        guard found == nil else {
            await undoImportedSerial(written, for: id)
            throw LicenseRepositoryError.duplicateID(id)
        }

        do {
            modelContext.insert(license)
            try persist()
        } catch {
            modelContext.rollback()
            await undoImportedSerial(written, for: id)
            throw error
        }
    }

    /// Replace branch: every field and both dates come from the backup (D3). The local serial is
    /// kept when the file has none.
    private func replaceImported(_ record: LicenseSummary, serial wanted: String?) async throws {
        let id = record.id
        let written = try await writeImportedSerial(wanted, for: id)

        // I2: fetch again after the serial store step.
        let found: License?
        do {
            found = try fetchLicense(id)
        } catch {
            await undoImportedSerial(written, for: id)
            throw error
        }
        guard let license = found else {
            // Defensive: unreachable under I3.
            await undoImportedSerial(written, for: id)
            throw LicenseRepositoryError.notFound(id)
        }

        do {
            try license.restore(
                productName: record.productName,
                vendor: record.vendor,
                registeredName: record.registeredName,
                registeredEmail: record.registeredEmail,
                purchaseDate: record.purchaseDate,
                version: record.version,
                notes: record.notes,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            try persist()
        } catch {
            modelContext.rollback()
            await undoImportedSerial(written, for: id)
            throw error
        }
    }

    /// Saves `wanted` for `id`, reading the previous value first (also for a new license: an orphan
    /// item may exist, plan 0010 F5). Returns what the store held before when this call wrote, nil
    /// when it wrote nothing (no serial in the file, or the same value already stored).
    /// `.undecodableData` on the read does not block the write; any other read error stops before it.
    private func writeImportedSerial(_ wanted: String?, for id: UUID) async throws -> PreviousSerial? {
        guard let wanted else { return nil }
        let previous = try await readPreviousSerial(for: id)
        if case .value(let current) = previous, current == wanted { return nil }
        try await serials.save(wanted, for: id)
        return previous
    }

    /// D4 undo of the serial written by this same import call, run after `rollback()`. Errors are
    /// discarded and the caller throws the original error; a failed undo leaves residue, as for
    /// `create` and `update` (R12).
    private func undoImportedSerial(_ previous: PreviousSerial?, for id: UUID) async {
        switch previous {
        case nil:
            // This call wrote nothing.
            break
        case .absent?:
            // The item did not exist before this call: remove only what this call created.
            try? await serials.deleteSerial(for: id)
        case .value(let old)?:
            // Puts back the item that existed before (a replaced license, or an orphan).
            try? await serials.save(old, for: id)
        case .unreadable?:
            // The previous value is unknown: the new value stays (D9 of plan 0004).
            break
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
            registeredName: license.registeredName,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            createdAt: license.createdAt,
            updatedAt: license.updatedAt
        )
    }
}
