import Foundation
import Security

/// Cryptographically secure random bytes from the system generator. Default salt source of
/// `EncryptedBackupService`.
enum BackupRandom {
    /// `count` random bytes from `SecRandomCopyBytes`; a failure throws `encryptionFailed`.
    static func bytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw BackupExportError.encryptionFailed }
        return Data(bytes)
    }
}
