import CryptoKit
import Foundation
import Testing
@testable import SerialManager

/// Reader of the import (ADR 0002 section 5; plan 0010, 2.6 and T2). Fake files and passwords only.
struct BackupReaderTests {
    private typealias F = BackupFixtures

    /// Thrown by a stub key derivation: the header checks passed and step 5 was reached.
    private struct ReachedDerivation: Error {}

    private struct Outcome {
        let result: Result<BackupPayload, any Error>
        /// Iteration count of every `deriveKey` call.
        let derivations: [UInt32]

        var error: (any Error)? {
            if case .failure(let error) = result { error } else { nil }
        }
    }

    private enum Derivation {
        case real
        case stub(any Error)
    }

    private func read(at url: URL, password: String = F.password, derivation: Derivation = .real) -> Outcome {
        var derivations: [UInt32] = []
        let result = Result {
            try BackupReader.read(from: url, password: password) { password, salt, iterations in
                derivations.append(iterations)
                switch derivation {
                case .real:
                    return try BackupKeyDerivation.key(password: password, salt: salt, iterations: iterations)
                case .stub(let error):
                    throw error
                }
            }
        }
        return Outcome(result: result, derivations: derivations)
    }

    private func read(_ file: Data, password: String = F.password, derivation: Derivation = .real) throws -> Outcome {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file()
        try file.write(to: url)
        return read(at: url, password: password, derivation: derivation)
    }

    /// A file of `size` bytes starting with `start`, sparse on APFS (F8).
    private func sparseFile(in directory: TemporaryDirectory, start: Data, size: UInt64) throws -> URL {
        let url = directory.file()
        try start.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        return url
    }

    private var expectedFixturePayload: BackupPayload {
        BackupPayload(exportedAt: F.exportedAt, licenses: [
            BackupPayload.Entry(F.editor, serial: F.editorSerial),
            BackupPayload.Entry(F.viewer, serial: nil),
        ])
    }

    // MARK: Fixture and A1

    @Test func fixtureIsAVersionOneFileOfTheTestReader() throws {
        let contents = try BackupFileReader.parse(BackupImportFixture.data)
        #expect(contents.version == 1)
        #expect(contents.iterations == 600_000)
        #expect(contents.salt == F.salt)
        #expect(contents.nonce == F.nonceBytes)
        #expect(try BackupFileReader.payload(BackupImportFixture.data, password: F.password) == expectedFixturePayload)
    }

    @Test func fixtureDecodesIntoBothEntriesAtMillisecondPrecision() throws {
        let outcome = try read(BackupImportFixture.data)
        let payload = try outcome.result.get()
        #expect(payload == expectedFixturePayload)
        #expect(payload.licenses.map(\.createdAt) == [F.editorCreated, F.viewerCreated])
        #expect(payload.licenses.first?.updatedAt == F.editorUpdated)
        #expect(payload.licenses.last?.purchaseDate == F.viewerPurchased)
        #expect(outcome.derivations == [600_000])
    }

    // MARK: A3, wrong password and altered bytes

    @Test func wrongPasswordFails() throws {
        let outcome = try read(BackupImportFixture.data, password: "sample-backup-paSS")
        #expect(outcome.error as? BackupError == .wrongPassword)
        #expect(outcome.derivations.count == 1)
    }

    @Test func alteredHeaderByteFailsAsWrongPassword() throws {
        var bytes = BackupImportFixture.bytes
        bytes[17 + 16] ^= 0x01  // first nonce byte: part of the associated data
        let outcome = try read(Data(bytes))
        #expect(outcome.error as? BackupError == .wrongPassword)
    }

    @Test func emptyPasswordFailsWithoutDerivingAKey() throws {
        let outcome = try read(BackupImportFixture.data, password: "")
        #expect(outcome.error as? BackupError == .wrongPassword)
        #expect(outcome.derivations.isEmpty)
    }

    @Test func keyDerivationFailureIsNotAPasswordError() throws {
        let outcome = try read(BackupImportFixture.data, derivation: .stub(BackupExportError.encryptionFailed))
        #expect(outcome.error as? BackupImportError == .keyDerivationFailed)
    }

    // MARK: A4, corrupted files

    enum Corruption: String, CaseIterable, CustomTestStringConvertible {
        case nineBytes, wrongMagic, versionZero, kdfID, iterationsBelow, iterationsAbove
        case saltTooShort, saltTooLong, cipherID, cutHeader, lastByteRemoved, byteAppended

        var testDescription: String { rawValue }

        var file: Data {
            var builder = BackupFileBuilder()
            switch self {
            case .nineBytes: return BackupFileBuilder().unsealed().prefix(9)
            case .wrongMagic: builder.magic = Data("SMBACKUQ".utf8)
            case .versionZero: builder.version = 0
            case .kdfID: builder.kdfID = 0x02
            case .iterationsBelow: builder.iterations = 599_999
            case .iterationsAbove: builder.iterations = 10_000_001
            case .saltTooShort: builder.salt = Data(repeating: 0xA0, count: 15)
            case .saltTooLong: builder.salt = Data(repeating: 0xA0, count: 65)
            case .cipherID: builder.cipherID = 0x02
            case .cutHeader: return BackupFileBuilder().unsealed().prefix(40)
            case .lastByteRemoved: return BackupFileBuilder().unsealed().dropLast()
            case .byteAppended: return BackupFileBuilder().unsealed() + Data([0x00])
            }
            return builder.unsealed()
        }
    }

    @Test(arguments: Corruption.allCases)
    func corruptedFileFailsBeforeAnyKey(_ corruption: Corruption) throws {
        let outcome = try read(corruption.file)
        #expect(outcome.error as? BackupError == .corruptedFile)
        #expect(outcome.derivations.isEmpty)
    }

    @Test func emptyFileIsCorrupted() throws {
        let outcome = try read(Data())
        #expect(outcome.error as? BackupError == .corruptedFile)
    }

    @Test func fileAboveTheSizeCapIsCorrupted() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try sparseFile(
            in: directory, start: BackupFileBuilder().unsealed(),
            size: UInt64(BackupFormat.maxBackupFileSize) + 1)
        let outcome = read(at: url)
        #expect(outcome.error as? BackupError == .corruptedFile)
        #expect(outcome.derivations.isEmpty)
    }

    @Test func fileAtTheSizeCapPassesTheSizeCheck() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let size = BackupFormat.maxBackupFileSize
        let builder = BackupFileBuilder()
        let header = builder.header(ciphertextLength: size - builder.header(ciphertextLength: 0).count - 16)
        let url = try sparseFile(in: directory, start: header, size: UInt64(size))
        let outcome = read(at: url, derivation: .stub(ReachedDerivation()))
        #expect(outcome.error is ReachedDerivation)
    }

    // MARK: A5, newer versions

    @Test func newerVersionIsUnsupportedBeforeAnyOtherCheck() throws {
        var builder = BackupFileBuilder()
        builder.version = 2
        builder.kdfID = 0x02
        let outcome = try read(builder.unsealed())
        #expect(outcome.error as? BackupError == .unsupportedVersion)
        #expect(outcome.derivations.isEmpty)
    }

    @Test func newerVersionInATenByteFileIsUnsupported() throws {
        var builder = BackupFileBuilder()
        builder.version = 2
        let outcome = try read(builder.unsealed().prefix(10))
        #expect(outcome.error as? BackupError == .unsupportedVersion)
    }

    @Test func newerVersionWithAnInvalidHeaderAboveTheSizeCapIsUnsupported() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var builder = BackupFileBuilder()
        builder.version = 2
        builder.kdfID = 0x02
        let url = try sparseFile(
            in: directory, start: builder.unsealed(), size: UInt64(BackupFormat.maxBackupFileSize) + 1)
        let outcome = read(at: url)
        #expect(outcome.error as? BackupError == .unsupportedVersion)
        #expect(outcome.derivations.isEmpty)
    }

    // MARK: Bounds

    @Test func importBoundsMatchTheADR() {
        #expect(BackupFormat.importIterationRange.lowerBound == 600_000)
        #expect(BackupFormat.importIterationRange.upperBound == 10_000_000)
        #expect(BackupFormat.importSaltLengthRange.lowerBound == 16)
        #expect(BackupFormat.importSaltLengthRange.upperBound == 64)
        #expect(BackupFormat.firstReadLength == 10)
    }

    @Test(arguments: [(600_000, 16), (10_000_000, 16), (600_000, 64), (10_000_000, 64)] as [(UInt32, Int)])
    func headerAtTheBoundsReachesKeyDerivation(iterations: UInt32, saltLength: Int) throws {
        var builder = BackupFileBuilder()
        builder.iterations = iterations
        builder.salt = Data(repeating: 0xA5, count: saltLength)
        let outcome = try read(builder.unsealed(), derivation: .stub(ReachedDerivation()))
        #expect(outcome.error is ReachedDerivation)
        #expect(outcome.derivations == [iterations])
    }

    // MARK: A7, Unicode normalisation

    @Test func decomposedPasswordOpensWithThePrecomposedOne() throws {
        let plaintext = try BackupPayloadJSON.payload(entries: [BackupPayloadJSON.entry()])
        let file = try BackupFileBuilder().sealed(plaintext, password: "cafe\u{301}-sample-pw")
        let payload = try read(file, password: "caf\u{E9}-sample-pw").result.get()
        #expect(payload.licenses.map(\.productName) == ["Sample Editor"])
    }

    // MARK: A6 end to end

    @Test func sealedPayloadWithADuplicateIDIsCorrupted() throws {
        let plaintext = try BackupPayloadJSON.payload(entries: [
            BackupPayloadJSON.entry(), BackupPayloadJSON.entry(name: "Sample Viewer"),
        ])
        let file = try BackupFileBuilder().sealed(plaintext, password: F.password)
        let outcome = try read(file)
        #expect(outcome.error as? BackupError == .corruptedFile)
    }

    @Test func sealedPayloadWithAnUnknownKeyAndWholeSecondDatesDecodes() throws {
        var entry = BackupPayloadJSON.entry()
        entry["color"] = "red"
        entry["createdAt"] = "2026-01-01T09:00:00Z"
        let plaintext = try BackupPayloadJSON.payload([entry], exportedAt: "2026-01-01T10:00:00Z")
        let file = try BackupFileBuilder().sealed(plaintext, password: F.password)
        let payload = try read(file).result.get()
        #expect(payload.exportedAt == Date(timeIntervalSince1970: 1_767_261_600))
        #expect(payload.licenses.first?.createdAt == Date(timeIntervalSince1970: 1_767_258_000))
    }

    // MARK: File errors

    @Test func missingFileRethrowsTheOpenError() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let outcome = read(at: directory.file("Missing.smbackup"))
        let error = try #require(outcome.error)
        #expect(!(error is BackupError))
        #expect(!(error is BackupImportError))
        #expect(outcome.derivations.isEmpty)
    }
}

/// `BackupImportError` messages (plan 0010, 2.5). Expectations are built as the code builds them,
/// never from an English literal, so the tests pass in any system language.
struct BackupImportErrorTests {
    @Test func interruptedNamesTheCountsAndTheUnderlyingMessage() {
        let error = BackupImportError.interrupted(imported: 2, replaced: 0, underlyingMessage: "X")
        let expected = String(localized: "The import stopped. Imported: \(2). Replaced: \(0).") + " X"
        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [BackupImportError.noPendingImport, .keyDerivationFailed])
    func otherCasesHaveNoDedicatedMessage(_ error: BackupImportError) {
        #expect(error.errorDescription == nil)
    }
}
