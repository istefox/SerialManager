import CryptoKit
import Foundation

/// Real backup service: writes and reads the encrypted backup of docs/adr/0002-backup-format.md.
///
/// An actor, so the key derivation, the encryption and the decryption never run on the main actor;
/// the import reads the file in a detached task, so the actor stays free for `cancelImport()`.
///
/// The password and the derived key are locals, never stored, logged or put in an error. The export
/// plaintext is a local of `export(to:password:)`. The decrypted import entries, serials included,
/// are kept in memory between `prepareImport` and the next `applyImport`, `cancelImport()` or
/// `prepareImport`, and never written anywhere but the library and the Keychain.
actor EncryptedBackupService: BackupService {
    /// The payload of the last successful `prepareImport`, waiting for `applyImport` (D5).
    private struct PendingImport: Sendable {
        let url: URL
        let entries: [BackupPayload.Entry]
    }

    private var pendingImport: PendingImport?
    /// Bumped by every `prepareImport` and `cancelImport()`: a prepare stores its payload only if
    /// nothing bumped it while it was suspended (R17).
    private var importGeneration = 0

    private let repository: any LicenseRepository
    private let saltSource: @Sendable (Int) throws -> Data
    private let nonceSource: @Sendable () -> AES.GCM.Nonce
    private let now: @Sendable () -> Date
    private let maxFileSize: Int
    private let deriveKey: @Sendable (String, Data, UInt32) throws -> SymmetricKey
    private let seal: @Sendable (Data, SymmetricKey, AES.GCM.Nonce, Data) throws -> AES.GCM.SealedBox

    /// - Parameters:
    ///   - saltSource: random bytes for the salt; tests inject fixed bytes.
    ///   - nonceSource: the GCM nonce; tests inject a fixed one.
    ///   - now: the export date written in the payload.
    ///   - maxFileSize: tests only. Production code keeps the default, `BackupFormat.maxBackupFileSize`.
    ///   - deriveKey: tests only. Production code keeps the default, `BackupKeyDerivation.key`.
    ///   - seal: tests only. Production code keeps the default, AES-GCM sealing of the plaintext
    ///     with the header as associated data.
    init(
        repository: any LicenseRepository,
        saltSource: @escaping @Sendable (Int) throws -> Data = BackupRandom.bytes,
        nonceSource: @escaping @Sendable () -> AES.GCM.Nonce = { AES.GCM.Nonce() },
        now: @escaping @Sendable () -> Date = { Date() },
        maxFileSize: Int = BackupFormat.maxBackupFileSize,
        deriveKey: @escaping @Sendable (String, Data, UInt32) throws -> SymmetricKey = {
            try BackupKeyDerivation.key(password: $0, salt: $1, iterations: $2)
        },
        seal: @escaping @Sendable (Data, SymmetricKey, AES.GCM.Nonce, Data) throws -> AES.GCM.SealedBox = {
            try AES.GCM.seal($0, using: $1, nonce: $2, authenticating: $3)
        }
    ) {
        self.repository = repository
        self.saltSource = saltSource
        self.nonceSource = nonceSource
        self.now = now
        self.maxFileSize = maxFileSize
        self.deriveKey = deriveKey
        self.seal = seal
    }

    nonisolated var isExportAvailable: Bool { true }

    nonisolated var isImportAvailable: Bool { true }

    /// Writes every license and its serial to `url`, encrypted with `password`.
    ///
    /// Nothing is written before the last step: any failure leaves the destination as it was.
    /// Repository, serial store and file write errors are rethrown unchanged.
    func export(to url: URL, password: String) async throws -> ExportSummary {
        // 1. Licenses in a stable order.
        let licenses = try await repository.fetchAll().sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }

        // 2. Serials; a failed read aborts the export.
        var entries: [BackupPayload.Entry] = []
        entries.reserveCapacity(licenses.count)
        for license in licenses {
            let serial = try await repository.serial(for: license.id)
            entries.append(BackupPayload.Entry(license, serial: serial))
        }
        let missingSerialCount = entries.filter { $0.serial == nil }.count

        // 3. Plaintext.
        let payload = BackupPayload(exportedAt: now(), licenses: entries)
        let plaintext = try BackupPayload.makeEncoder().encode(payload)

        // 4. Size cap, before any key is derived. GCM ciphertext is as long as the plaintext.
        let saltLength = BackupFormat.saltLength
        let fileSize = BackupFormat.fileSize(saltLength: saltLength, ciphertextLength: plaintext.count)
        guard BackupFormat.fitsSizeLimit(fileSize, maxFileSize: maxFileSize),
              let ciphertextLength = UInt32(exactly: plaintext.count)
        else {
            throw BackupExportError.fileTooLarge
        }

        // 5. Salt and nonce.
        let salt = try saltSource(saltLength)
        let nonce = nonceSource()
        let nonceBytes = nonce.withUnsafeBytes { Data($0) }
        guard salt.count == saltLength, nonceBytes.count == BackupFormat.nonceLength else {
            throw BackupExportError.encryptionFailed
        }

        // 6. Header and key.
        let header = BackupFormat.header(salt: salt, nonce: nonceBytes, ciphertextLength: ciphertextLength)
        let key = try deriveKey(password, salt, BackupFormat.iterations)

        // 7. Seal with the header as associated data.
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try seal(plaintext, key, nonce, header)
        } catch {
            throw BackupExportError.encryptionFailed
        }
        var file = header
        file.append(sealed.ciphertext)
        file.append(sealed.tag)
        guard file.count == fileSize else {
            assertionFailure("Backup size differs from the precomputed size")
            throw BackupExportError.encryptionFailed
        }

        // 8. Atomic write: the destination is replaced only once the new file is complete.
        try file.write(to: url, options: .atomic)

        return ExportSummary(licenseCount: entries.count, missingSerialCount: missingSerialCount)
    }

    /// Reads, decrypts and validates `url` (ADR 0002, section 5) and keeps its payload for
    /// `applyImport`. Writes nothing (R4): the library is only read, to find the conflicts.
    ///
    /// Any earlier pending payload is dropped first (D5). If `cancelImport()` or another
    /// `prepareImport` runs while this one is suspended, this one still returns its preview or its
    /// error but keeps no payload (R17).
    /// - Throws: `BackupError`, `BackupImportError.keyDerivationFailed`, the file's open or read
    ///   error, or the repository's error, unchanged.
    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        pendingImport = nil
        importGeneration &+= 1
        let generation = importGeneration
        let deriveKey = self.deriveKey
        let payload = try await Task.detached {
            try BackupReader.read(from: url, password: password, deriveKey: deriveKey)
        }.value
        let existing = Set(try await repository.fetchAll().map(\.id))
        let conflicts = existing.intersection(payload.licenses.map(\.id))
        if generation == importGeneration {
            pendingImport = PendingImport(url: url, entries: payload.licenses)
        }
        return ImportPreview(fileURL: url, licenseCount: payload.licenses.count, conflictingIDs: conflicts)
    }

    /// Writes the pending payload in file order, one repository call per license (D4), and stops at
    /// the first failure (D1). Conflicts are decided per license by the repository at this moment,
    /// not by the preview (R9).
    ///
    /// The payload is taken and dropped before the first suspension, whatever the outcome: a second
    /// apply, or one after a failure, finds nothing (R11, D5).
    /// - Throws: `BackupImportError.noPendingImport` when no payload matches `preview`;
    ///   `BackupImportError.interrupted` when a write fails, the licenses written before it staying
    ///   written.
    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        let pending = pendingImport
        pendingImport = nil
        guard let pending, pending.url == preview.fileURL, pending.entries.count == preview.licenseCount else {
            throw BackupImportError.noPendingImport
        }
        var imported = 0
        var replaced = 0
        var skipped = 0
        for entry in pending.entries {
            do {
                switch try await repository.importLicense(entry.summary, serial: entry.serial, policy: policy) {
                case .created: imported += 1
                case .replaced: replaced += 1
                case .skipped: skipped += 1
                }
            } catch {
                throw BackupImportError.interrupted(
                    imported: imported, replaced: replaced, underlyingMessage: error.localizedDescription)
            }
        }
        return ImportSummary(imported: imported, replaced: replaced, skipped: skipped)
    }

    /// Drops the pending payload and stops a running `prepareImport` from keeping one (D5, R17).
    /// Does not touch an `applyImport` already running: it took the payload before its first await.
    func cancelImport() {
        pendingImport = nil
        importGeneration &+= 1
    }
}

private extension BackupPayload.Entry {
    /// The license fields of this entry, as `LicenseRepository.importLicense` takes them.
    var summary: LicenseSummary {
        LicenseSummary(
            id: id,
            productName: productName,
            vendor: vendor,
            registeredName: registeredName,
            registeredEmail: registeredEmail,
            purchaseDate: purchaseDate,
            version: version,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
