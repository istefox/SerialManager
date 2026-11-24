import CryptoKit
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
    private let attachments: AttachmentFileStore
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
    ///   - attachments: where the encrypted attachment files live and which key seals them. No
    ///     default: a test or a preview must inject its own directory and key store, because Debug
    ///     and Release share one bundle identifier (SPEC 0018, R9, R10 and A18).
    ///   - beforeSave: runs before every `save()`; tests make it throw to force a persist failure.
    init(
        modelContainer: ModelContainer,
        serials: any SerialStore,
        attachments: AttachmentFileStore,
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
        self.attachments = attachments
        self.makeID = makeID
        self.now = now
        self.beforeSave = beforeSave
    }

    // MARK: Reads (no lock: by I1 the context holds committed state only across suspensions)

    func fetchAll() async throws -> [LicenseSummary] {
        // One grouped fetch of every attachment row, not one fetch per license.
        let grouped = try attachmentSummariesByLicense()
        return try modelContext.fetch(FetchDescriptor<License>()).map {
            LicenseSummary($0, attachments: grouped[$0.id] ?? [])
        }
    }

    /// Whether the encrypted file of `id` is still on disk.
    ///
    /// A `stat`, nothing more: no decryption, no Keychain call, no throw. The detail view calls it
    /// to show a row whose file is gone as unreadable but still removable (R13, R21), the same way
    /// a missing Keychain item is surfaced today instead of being carried in `LicenseSummary`.
    func attachmentIsReadable(id: UUID) async -> Bool {
        attachments.fileExists(id: id)
    }

    func attachmentData(id: UUID) async throws -> Data {
        guard let record = try fetchAttachment(id) else { throw AttachmentError.notFound(id) }
        // A file that is already gone has no bytes to decrypt, so it is reported as missing before
        // the key is asked for: an export must be able to count and skip it even when the key is
        // missing or denied (R13). A file that is there still needs the key (R10).
        // `presence` throws for an unreadable path instead of calling it missing (SM-03).
        guard try attachments.presence(id: record.id) else { throw AttachmentError.fileMissing(record.id) }
        // Never generates a key: a library with attachments whose key is gone must say so (R10).
        let key = try await attachments.key(generateIfMissing: false)
        return try attachments.read(id: record.id, key: key)
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
        // A new license has no attachment yet.
        return LicenseSummary(license)
    }

    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        // Same rule as `License.validate`, so `License.update` cannot throw for it later (R5).
        guard draft.hasValidProductName else { throw LicenseValidationError.emptyProductName }
        guard try fetchLicense(id) != nil else { throw LicenseRepositoryError.notFound(id) }

        // An untouched serial is not read, compared or written: whatever the store holds now
        // stays, even when it changed after the form opened (SM-01).
        let old: PreviousSerial
        let wroteSerial: Bool
        if draft.leavesSerialUntouched {
            old = .absent
            wroteSerial = false
        } else {
            old = try await readPreviousSerial(for: id)
            wroteSerial = try await applySerial(draft.serial, over: old, for: id)
        }

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
        return try summary(license)
    }

    func delete(id: UUID) async throws {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        let old = try await readPreviousSerial(for: id)
        // Serial first (D1): if this fails, the entry is not touched. Runs for an unknown id too (R10).
        try await serials.deleteSerial(for: id)

        // Rows go in the same save as the license, so no row survives its license (R13).
        let attachmentIDs: [UUID]
        do {
            guard let license = try fetchLicense(id) else { return }
            let rows = try fetchAttachments(of: id)
            attachmentIDs = rows.map(\.id)
            for row in rows { modelContext.delete(row) }
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

        // Files last, once the rows are gone: a failure here leaves an orphan file, which is
        // invisible and harmless, and never a row pointing at a missing file (R12, R13).
        for attachmentID in attachmentIDs {
            try? attachments.delete(id: attachmentID)
        }
    }

    // MARK: Attachments

    func addAttachment(_ file: AttachmentFile, to licenseID: UUID) async throws -> LicenseSummary {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard AttachmentRecord.isValidFileName(file.fileName) else {
            throw AttachmentValidationError.emptyFileName
        }
        guard let license = try fetchLicense(licenseID) else {
            throw LicenseRepositoryError.notFound(licenseID)
        }

        // Limits before anything is written (R16). Measured on the plaintext.
        let existingRows = try modelContext.fetch(FetchDescriptor<AttachmentRecord>())
        try AttachmentLimits.check(
            byteCount: file.byteCount,
            fileName: file.fileName,
            licenseBytes: existingRows.filter { $0.licenseID == licenseID }.reduce(0) { $0 + $1.byteCount },
            libraryBytes: existingRows.reduce(0) { $0 + $1.byteCount }
        )

        // The first attachment of the library may create the key; any later one must not (R10).
        let key = try await attachments.key(generateIfMissing: existingRows.isEmpty)

        // I2: fetch again after the key step, and take the row count again with it.
        guard try fetchLicense(licenseID) != nil else {
            throw LicenseRepositoryError.notFound(licenseID)
        }

        let record = try AttachmentRecord(
            licenseID: licenseID,
            fileName: file.fileName,
            byteCount: file.byteCount,
            contentType: file.contentType,
            addedAt: now()
        )

        // File first, then the row (R12): no metadata row ever points at a missing file.
        try attachments.write(file.data, id: record.id, key: key)
        do {
            modelContext.insert(record)
            // D9: adding an attachment bumps the license's `updatedAt`. `License` is not modified
            // by this ticket (D6), so the bump goes through its own `update`, with its own values.
            try bumpUpdatedAt(license)
            try persist()
        } catch {
            modelContext.rollback()
            // Compensation: remove the file this call wrote, so no file outlives its failed row.
            try? attachments.delete(id: record.id)
            throw error
        }
        return try summary(license)
    }

    func removeAttachment(id: UUID) async throws -> LicenseSummary {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard let record = try fetchAttachment(id) else { throw AttachmentError.notFound(id) }
        let licenseID = record.licenseID
        guard let license = try fetchLicense(licenseID) else {
            throw LicenseRepositoryError.notFound(licenseID)
        }

        // Row first, then the file: a failure to delete the file leaves an orphan file (harmless,
        // R13), never a row pointing at a missing file.
        do {
            modelContext.delete(record)
            try bumpUpdatedAt(license)
            try persist()
        } catch {
            modelContext.rollback()
            throw error
        }
        // Succeeds when the file is already gone, so an unreadable attachment is removable (R13).
        try? attachments.delete(id: id)
        return try summary(license)
    }

    /// Sets `updatedAt` to now by replaying the license's current fields through its own `update`
    /// (D6: `License` gains no write path for this ticket).
    private func bumpUpdatedAt(_ license: License) throws {
        try license.update(
            productName: license.productName,
            vendor: license.vendor,
            registeredName: license.registeredName,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            now: now()
        )
    }

    // MARK: Import

    /// Writes one license of a backup (plan 0010, 2.3). See `LicenseRepository.importLicense`.
    ///
    /// Runs under the mutation lock (I3), so no other mutation slips between the id lookup and the
    /// write, and the SwiftData upsert on `@Attribute(.unique)` is never what decides a conflict.
    /// The serial rules are its own: `applySerial` and `restoreSerial` are not reused, because an
    /// import never removes a Keychain item that existed before the call (plan 0010, F4).
    func importLicense(
        _ record: LicenseSummary,
        serial: String?,
        attachments importedAttachments: [AttachmentImport],
        policy: ConflictPolicy
    ) async throws -> LicenseImportOutcome {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        // Same rule as `License.validate`, checked before any write in both branches.
        guard License.isValidProductName(record.productName) else {
            throw LicenseValidationError.emptyProductName
        }
        for attachment in importedAttachments where !AttachmentRecord.isValidFileName(attachment.fileName) {
            throw AttachmentValidationError.emptyFileName
        }
        // `""` counts as no serial (ADR 0002).
        let wanted = serial.flatMap { $0.isEmpty ? nil : $0 }

        let exists = try fetchLicense(record.id) != nil
        switch (exists, policy) {
        case (true, .skip):
            // No serial store call, no context change, and no attachment touched (R25).
            return .skipped
        case (true, .replace):
            try await replaceImported(record, serial: wanted, attachments: importedAttachments)
            return .replaced
        case (false, _):
            try await createImported(record, serial: wanted, attachments: importedAttachments)
            return .created
        }
    }

    /// The attachments of `pending` that this library does not already hold, by id (D12, R25).
    ///
    /// An id already present locally is left alone, so its bytes, name and dates stay as they are.
    /// No size limit is applied: an import never refuses an attachment for being over a limit.
    private func newImportedAttachments(_ pending: [AttachmentImport]) throws -> [AttachmentImport] {
        guard !pending.isEmpty else { return [] }
        let known = Set(try modelContext.fetch(FetchDescriptor<AttachmentRecord>()).map(\.id))
        var seen = Set<UUID>()
        return pending.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Writes the files and inserts the rows of `pending`, inside the caller's pending save.
    ///
    /// Call sites hold no unsaved change across an `await`: the key is resolved before, and this
    /// method is synchronous. `written` collects the ids whose file this call created, so the
    /// caller can delete exactly those and no others (R15). It is `inout` on purpose: a `return`
    /// value would be lost when attachment *k* of *n* throws, leaving the first *k* files on disk
    /// with nothing allowed to sweep them later (R13).
    private func insertImportedAttachments(
        _ pending: [AttachmentImport],
        licenseID: UUID,
        key: SymmetricKey?,
        written: inout [UUID]
    ) throws {
        guard !pending.isEmpty else { return }
        guard let key else { throw AttachmentError.keyMissing }
        for attachment in pending {
            let row = try AttachmentRecord(
                id: attachment.id,
                licenseID: licenseID,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount,
                contentType: attachment.contentType,
                addedAt: attachment.addedAt
            )
            try self.attachments.write(attachment.data, id: attachment.id, key: key)
            written.append(attachment.id)
            modelContext.insert(row)
        }
    }

    /// Create branch: the id has no license.
    ///
    /// With no serial in the file, an orphan item already stored under this id stays in place and the
    /// new license shows it. Accepted edge (plan 0010, 2.3): an import never removes an item it did not
    /// create.
    private func createImported(
        _ record: LicenseSummary, serial wanted: String?, attachments pending: [AttachmentImport]
    ) async throws {
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

        // Key before any context change and before the serial step, so no unsaved change is held
        // across an `await` (I1). Generated only when the library holds no attachment at all (R10).
        // The set is taken before the key and is not recomputed: I3 keeps every other mutation out.
        let toWrite = try newImportedAttachments(pending)
        let key = try await importKey(for: toWrite)

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

        var files: [UUID] = []
        do {
            modelContext.insert(license)
            try insertImportedAttachments(toWrite, licenseID: id, key: key, written: &files)
            try persist()
        } catch {
            modelContext.rollback()
            // Only the files this call wrote (R15): an id already present locally was skipped.
            for fileID in files { try? self.attachments.delete(id: fileID) }
            await undoImportedSerial(written, for: id)
            throw error
        }
    }

    /// The key an import needs for `pending`, or nil when it needs none.
    ///
    /// A backup carrying attachments into a library that holds none creates the first key; with
    /// attachments already stored, a missing key throws instead of being replaced (R10).
    ///
    /// `pending` is the set that will actually be written (`newImportedAttachments`), not the raw
    /// list of the backup: a Replace whose attachments all exist locally writes no file and must
    /// not fail for a key it never uses (R25).
    private func importKey(for pending: [AttachmentImport]) async throws -> SymmetricKey? {
        guard !pending.isEmpty else { return nil }
        let isLibraryEmpty = try modelContext.fetch(FetchDescriptor<AttachmentRecord>()).isEmpty
        return try await attachments.key(generateIfMissing: isLibraryEmpty)
    }

    /// Replace branch: every field and both dates come from the backup (D3). The local serial is
    /// kept when the file has none.
    private func replaceImported(
        _ record: LicenseSummary, serial wanted: String?, attachments pending: [AttachmentImport]
    ) async throws {
        let id = record.id
        // Only the attachments this library lacks need a key (R25); see `createImported`.
        let toWrite = try newImportedAttachments(pending)
        let key = try await importKey(for: toWrite)
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

        var files: [UUID] = []
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
                // Both dates come from the backup: the merged attachments never bump `updatedAt`
                // (SPEC 0010 D3, SPEC 0018 D9 and R25).
                updatedAt: record.updatedAt
            )
            // Merge, never delete: a local attachment absent from the backup is left alone (D12).
            try insertImportedAttachments(toWrite, licenseID: id, key: key, written: &files)
            try persist()
        } catch {
            modelContext.rollback()
            for fileID in files { try? self.attachments.delete(id: fileID) }
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

    /// The attachment rows of one license, in the contract's order: `addedAt` then `fileName`
    /// (R11), with the row id last so the order is total.
    private func fetchAttachments(of licenseID: UUID) throws -> [AttachmentRecord] {
        let descriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.licenseID == licenseID })
        return try modelContext.fetch(descriptor).sorted(by: AttachmentRecord.isOrderedBefore)
    }

    private func fetchAttachment(_ id: UUID) throws -> AttachmentRecord? {
        var descriptor = FetchDescriptor<AttachmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Every attachment row of the store, grouped by license and already ordered.
    private func attachmentSummariesByLicense() throws -> [UUID: [AttachmentSummary]] {
        let rows = try modelContext.fetch(FetchDescriptor<AttachmentRecord>())
            .sorted(by: AttachmentRecord.isOrderedBefore)
        return Dictionary(grouping: rows, by: \.licenseID)
            .mapValues { $0.map(AttachmentSummary.init) }
    }

    /// Summary of a license fetched in this context, attachments included.
    private func summary(_ license: License) throws -> LicenseSummary {
        LicenseSummary(
            license,
            attachments: try fetchAttachments(of: license.id).map(AttachmentSummary.init)
        )
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

extension AttachmentRecord {
    /// The contract's order: `addedAt`, then `fileName` compared the way the list compares names,
    /// then `id` so two rows never swap places between two fetches of the same data.
    static func isOrderedBefore(_ lhs: AttachmentRecord, _ rhs: AttachmentRecord) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        switch lhs.fileName.localizedStandardCompare(rhs.fileName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

extension AttachmentSummary {
    init(_ record: AttachmentRecord) {
        self.init(
            id: record.id,
            fileName: record.fileName,
            byteCount: record.byteCount,
            contentType: record.contentType,
            addedAt: record.addedAt
        )
    }
}

private extension LicenseSummary {
    init(_ license: License, attachments: [AttachmentSummary] = []) {
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
            updatedAt: license.updatedAt,
            attachments: attachments
        )
    }
}
