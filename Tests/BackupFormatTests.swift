import Foundation
import Testing
@testable import SerialManager

/// Version 1 constants and header layout (ADR 0002, section 3), checked against literal bytes.
struct BackupFormatTests {
    @Test func constantsMatchTheADR() {
        #expect(BackupFormat.magic == Data("SMBACKUP".utf8))
        #expect(BackupFormat.version == 1)
        #expect(BackupFormat.kdfID == 0x01)
        #expect(BackupFormat.iterations == 600_000)
        #expect(BackupFormat.saltLength == 16)
        #expect(BackupFormat.cipherID == 0x01)
        #expect(BackupFormat.nonceLength == 12)
        #expect(BackupFormat.tagLength == 16)
        #expect(BackupFormat.maxBackupFileSize == 67_108_864)
    }

    @Test func fileSizeIsHeaderPlusCiphertextPlusTag() {
        #expect(BackupFormat.headerLength(saltLength: 16) == 49)
        #expect(BackupFormat.fileSize(saltLength: 16, ciphertextLength: 0) == 65)
        #expect(BackupFormat.fileSize(saltLength: 16, ciphertextLength: 100) == 33 + 16 + 100 + 16)
    }

    @Test func sizeLimitAcceptsTheCapAndRejectsOneMore() {
        let cap = BackupFormat.maxBackupFileSize
        #expect(BackupFormat.fitsSizeLimit(cap))
        #expect(!BackupFormat.fitsSizeLimit(cap + 1))
        #expect(BackupFormat.fitsSizeLimit(200, maxFileSize: 200))
        #expect(!BackupFormat.fitsSizeLimit(201, maxFileSize: 200))
    }

    @Test func headerBytesFollowTheLayout() {
        let salt = Data((0..<16).map { UInt8($0) })
        let nonce = Data(repeating: 0xEE, count: 12)
        let header = BackupFormat.header(salt: salt, nonce: nonce, ciphertextLength: 0x0102_0304)

        var expected: [UInt8] = [0x53, 0x4D, 0x42, 0x41, 0x43, 0x4B, 0x55, 0x50, 0x00, 0x01, 0x01, 0x00, 0x09, 0x27, 0xC0, 0x10]
        expected += Array(0..<16)
        expected += [0x01]
        expected += Array(repeating: 0xEE, count: 12)
        expected += [0x01, 0x02, 0x03, 0x04]
        #expect([UInt8](header) == expected)
        #expect(header.count == 49)
    }
}
