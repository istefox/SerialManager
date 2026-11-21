import CryptoKit
import Foundation

/// Real backup service: writes the encrypted export of docs/adr/0002-backup-format.md.
///
/// An actor, so the key derivation and the encryption never run on the main actor. Import is
/// not available until #10: both import methods throw `UnavailableBackupService.NotAvailable`.
///
/// The password, the derived key and the plaintext are locals of `export(to:password:)`; they are
/// never stored, logged or put in an error.
actor EncryptedBackupService: BackupService {
    private let repository: any LicenseRepository
    private let saltSource: @Sendable (Int) throws -> Data
    private let nonceSource: @Sendable () -> AES.GCM.Nonce
    private let now: @Sendable () -> Date
    private let maxFileSize: Int

    /// - Parameters:
    ///   - saltSource: random bytes for the salt; tests inject fixed bytes.
    ///   - nonceSource: the GCM nonce; tests inject a fixed one.
    ///   - now: the export date written in the payload.
    ///   - maxFileSize: tests only. Production code keeps the default, `BackupFormat.maxBackupFileSize`.
    init(
        repository: any LicenseRepository,
        saltSource: @escaping @Sendable (Int) throws -> Data = BackupRandom.bytes,
        nonceSource: @escaping @Sendable () -> AES.GCM.Nonce = { AES.GCM.Nonce() },
        now: @escaping @Sendable () -> Date = { Date() },
        maxFileSize: Int = BackupFormat.maxBackupFileSize
    ) {
        self.repository = repository
        self.saltSource = saltSource
        self.nonceSource = nonceSource
        self.now = now
        self.maxFileSize = maxFileSize
    }

    nonisolated var isExportAvailable: Bool { true }

    /// Import is implemented by #10.
    nonisolated var isImportAvailable: Bool { false }

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
        let key = try BackupKeyDerivation.key(password: password, salt: salt, iterations: BackupFormat.iterations)

        // 7. Seal with the header as associated data.
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
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

    func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
        throw UnavailableBackupService.NotAvailable()
    }

    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
        throw UnavailableBackupService.NotAvailable()
    }
}
