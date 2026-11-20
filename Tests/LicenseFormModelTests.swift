import Foundation
import Testing
@testable import SerialManager

@MainActor
struct LicenseFormModelTests {
    private func loadedStore() async -> LicenseStore {
        let store = LicenseStore(repository: InMemoryLicenseRepository.sample())
        await store.load()
        return store
    }

    @Test func emptyNameBlocksSaveAndShowsError() async {
        let store = await loadedStore()
        let model = LicenseFormModel()
        model.draft.productName = "   "
        #expect(await model.save(to: store) == false)
        #expect(model.showsNameError)
        #expect(store.licenses.count == SampleData.entries.count)
    }

    @Test func newLicenseIsSaved() async {
        let store = await loadedStore()
        let model = LicenseFormModel()
        model.draft.productName = "Sample New App"
        #expect(await model.save(to: store))
        #expect(store.licenses.contains { $0.productName == "Sample New App" })
    }

    @Test func editLoadsSerialWithoutMarkingChanges() async {
        let store = await loadedStore()
        let model = LicenseFormModel(license: SampleData.first)
        #expect(model.isLoadingSerial)
        await model.loadSerial(from: store)
        #expect(!model.isLoadingSerial)
        #expect(model.draft.serial == "ACME-0000-TEST-0000")
        #expect(!model.hasChanges)
        model.draft.version = "9.9"
        #expect(model.hasChanges)
    }

    @Test func missingSerialLeavesFieldEmpty() async {
        let store = await loadedStore()
        let model = LicenseFormModel(license: SampleData.missingSerial)
        await model.loadSerial(from: store)
        #expect(model.draft.serial.isEmpty)
        #expect(!model.hasChanges)
    }

    @Test func purchaseDateToggle() {
        let model = LicenseFormModel()
        #expect(!model.hasPurchaseDate)
        model.hasPurchaseDate = true
        #expect(model.draft.purchaseDate != nil)
        model.hasPurchaseDate = false
        #expect(model.draft.purchaseDate == nil)
    }

    @Test func deleteRemovesLicense() async {
        let store = await loadedStore()
        let model = LicenseFormModel(license: SampleData.first)
        #expect(await model.delete(from: store))
        #expect(!store.licenses.contains { $0.id == SampleData.first.id })
    }

    @Test func unreadableSerialIsNotErasedOnSave() async {
        struct KeychainFailure: Error {}
        let repository = InMemoryLicenseRepository(entries: SampleData.entries)
        let store = LicenseStore(repository: repository)
        await store.load()
        await repository.setFailure(KeychainFailure())
        let model = LicenseFormModel(license: SampleData.first)
        await model.loadSerial(from: store)
        await repository.setFailure(nil)
        #expect(model.serialUnreadable)
        #expect(await model.save(to: store) == false)
        #expect(model.errorMessage != nil)
        #expect(await store.serial(for: SampleData.first.id) == .present("ACME-0000-TEST-0000"))
    }

    // MARK: D3, failed action drives the alert title

    private struct SampleFailure: Error {}

    @Test func failedDeleteSetsDeleteAction() async {
        let repository = InMemoryLicenseRepository(entries: SampleData.entries)
        let store = LicenseStore(repository: repository)
        await store.load()
        await repository.setFailure(SampleFailure())
        let model = LicenseFormModel(license: SampleData.first)
        #expect(await model.delete(from: store) == false)
        #expect(model.failedAction == .delete)
        #expect(model.errorMessage != nil)
    }

    @Test func failedSaveSetsSaveAction() async {
        let repository = InMemoryLicenseRepository(entries: SampleData.entries)
        let store = LicenseStore(repository: repository)
        await store.load()
        await repository.setFailure(SampleFailure())
        let model = LicenseFormModel()
        model.draft.productName = "Sample Failing App"
        #expect(await model.save(to: store) == false)
        #expect(model.failedAction == .save)
        #expect(model.errorMessage != nil)
    }

    @Test func unreadableSerialGuardSetsSaveAction() async {
        let repository = InMemoryLicenseRepository(entries: SampleData.entries)
        let store = LicenseStore(repository: repository)
        await store.load()
        await repository.setFailure(SampleFailure())
        let model = LicenseFormModel(license: SampleData.first)
        await model.loadSerial(from: store)
        await repository.setFailure(nil)
        #expect(await model.save(to: store) == false)
        #expect(model.failedAction == .save)
        #expect(model.errorMessage != nil)
    }

    @Test func failedSaveAfterFailedDeleteSetsSaveAction() async {
        let repository = InMemoryLicenseRepository(entries: SampleData.entries)
        let store = LicenseStore(repository: repository)
        await store.load()
        await repository.setFailure(SampleFailure())
        let model = LicenseFormModel(license: SampleData.first)
        await model.loadSerial(from: store)
        #expect(await model.delete(from: store) == false)
        #expect(model.failedAction == .delete)
        model.errorMessage = nil
        model.draft.serial = "SAMPLE-0000-FAKE-0000"
        #expect(await model.save(to: store) == false)
        #expect(model.failedAction == .save)
        #expect(model.errorMessage != nil)
    }
}
