import Foundation
import SwiftData
import Testing
@testable import SerialManager

/// Tests for the library factory and the unavailable state (SPEC 0004, R14 and D8; plan 0004, T2).
///
/// The only on-disk tests: each uses its own temporary directory, removed at the end, and passes
/// `InMemorySerialStore()` explicitly so the default `KeychainSerialStore()` is never created (R15).
@MainActor
struct LicenseLibraryTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LicenseLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the whole directory, SwiftData's sidecar files included.
    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func makeContainerCreatesDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let storeURL = root.appending(path: "Library/Licenses.store")

        let container = try LicenseLibrary.makeContainer(at: storeURL)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: storeURL.deletingLastPathComponent().path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<License>()) == 0)
    }

    @Test func makeRepositoryPersistsAcrossReopen() async throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        let storeURL = root.appending(path: "Library/Licenses.store")
        let serials = InMemorySerialStore()

        let first = LicenseLibrary.makeRepository(at: storeURL, serials: serials)
        #expect(first is SwiftDataLicenseRepository)
        let created = try await first.create(LicenseDraft(productName: "Example App", serial: "ACME-0000-TEST-0000"))

        let reopened = LicenseLibrary.makeRepository(at: storeURL, serials: serials)
        #expect(try await reopened.fetchAll().map(\.id) == [created.id])
        #expect(try await reopened.serial(for: created.id) == "ACME-0000-TEST-0000")
    }

    @Test func makeRepositoryFallsBackToUnavailable() async throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }
        // The parent of the store is a regular file, so the directory cannot be created.
        let blocker = root.appending(path: "Library")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))

        let repository = LicenseLibrary.makeRepository(
            at: blocker.appending(path: "Licenses.store"),
            serials: InMemorySerialStore()
        )

        #expect(repository is UnavailableLicenseRepository)
        await #expect(throws: LicenseRepositoryError.libraryUnavailable) { try await repository.fetchAll() }
        await #expect(throws: LicenseRepositoryError.libraryUnavailable) {
            try await repository.create(LicenseDraft(productName: "Example App"))
        }
    }

    @Test func unavailableShowsFailedPhase() async {
        let store = LicenseStore(repository: UnavailableLicenseRepository())

        await store.load()

        #expect(store.phase == .failed(LicenseRepositoryError.libraryUnavailable.localizedDescription))
        #expect(store.licenses.isEmpty)
    }
}
