import Foundation
import Testing
@testable import SerialManager

/// D4 and D10: the dedicated user-facing texts, and the generic text for every other error.
/// Expected texts are read from `errorDescription`, not hard-coded, so the tests pass in any
/// system language.
@MainActor
struct ErrorMessageTests {
    private var accessDeniedText: String? { SerialStoreError.accessDenied.errorDescription }

    @Test func accessDeniedHasDedicatedText() throws {
        let text = try #require(accessDeniedText)
        #expect(!text.isEmpty)
        #expect(SerialStoreError.accessDenied.localizedDescription == text)
    }

    @Test(arguments: [SerialStoreError.undecodableData, .unexpected(status: -25300)])
    func otherErrorsKeepGenericText(_ error: SerialStoreError) {
        #expect(error.errorDescription == nil)
        #expect(error.localizedDescription != accessDeniedText)
    }

    @Test func serialLookupShowsDedicatedText() async throws {
        let text = try #require(accessDeniedText)
        let store = LicenseStore(repository: InMemoryLicenseRepository(
            entries: SampleData.entries, failure: SerialStoreError.accessDenied))
        let lookup = await store.serial(for: SampleData.first.id)
        #expect(lookup == .failed(text))
    }

    @Test func formSaveShowsDedicatedText() async throws {
        let text = try #require(accessDeniedText)
        let store = LicenseStore(repository: InMemoryLicenseRepository(failure: SerialStoreError.accessDenied))
        let model = LicenseFormModel(draft: LicenseDraft(productName: "Example App"))
        let saved = await model.save(to: store)
        #expect(!saved)
        #expect(model.errorMessage == text)
    }
}
