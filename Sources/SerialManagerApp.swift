import SwiftUI

@main
struct SerialManagerApp: App {
    // Release builds use the persistent library: entries in SwiftData, serials in the Keychain
    // (LicenseLibrary). If the library cannot be opened, the window shows its failure state
    // instead of running on an in-memory store. Import and Export stay disabled until the
    // encrypted backup lands. Debug builds and previews run on in-memory fakes with fake
    // sample data.
    @State private var store: LicenseStore
    @State private var router = AppRouter()
    private let backupService: any BackupService

    init() {
        #if DEBUG
        if CommandLine.arguments.contains(KeychainSmokeCheck.argument) { KeychainSmokeCheck.runAndExit() }
        #endif
        #if DEBUG
        let repository = InMemoryLicenseRepository.sample()
        backupService = InMemoryBackupService(
            repository: repository,
            importLicenseCount: 5,
            importConflicts: Set(SampleData.licenses.prefix(2).map(\.id)))
        #else
        // No fake backup in release: it would report files that were never written.
        let repository = LicenseLibrary.makeRepository()
        backupService = UnavailableBackupService()
        #endif
        _store = State(initialValue: LicenseStore(repository: repository))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, router: router, backupService: backupService)
        }
        .commands {
            AppCommands(store: store, router: router, backupAvailable: backupService.isAvailable)
        }

        Settings {
            SettingsView()
        }
    }
}
