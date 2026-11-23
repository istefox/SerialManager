import Foundation
import Testing
@testable import SerialManager

/// User-facing texts of the export errors (plan 0009, section 2.3; SPEC R7, R12).
///
/// Each text is compared with a lookup of the exact English key through the app's catalog, so
/// the key is pinned verbatim and the tests pass in any system language.
struct BackupExportErrorTests {
    @Test func fileTooLargeUsesTheSpecText() throws {
        let text = try #require(BackupExportError.fileTooLarge.errorDescription)
        #expect(text == String(localized: "The backup is larger than 64 MB, the maximum size. Attachments are the usual cause: remove a few of the largest ones and try again."))
        #expect(BackupExportError.fileTooLarge.localizedDescription == text)
    }

    @Test func encryptionFailedUsesThePlanText() throws {
        let text = try #require(BackupExportError.encryptionFailed.errorDescription)
        #expect(text == String(localized: "The backup couldn't be encrypted. Try again."))
        #expect(BackupExportError.encryptionFailed.localizedDescription == text)
    }

    @Test func casesHaveDistinctTexts() {
        #expect(BackupExportError.fileTooLarge.errorDescription != BackupExportError.encryptionFailed.errorDescription)
    }
}
