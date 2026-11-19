import SwiftUI

@main
struct SerialManagerApp: App {
    // The data layer (SwiftData + Keychain) is not built yet: until it lands, the app runs
    // on in-memory fakes. Debug builds load fake sample data; release builds start empty
    // and have Import and Export disabled.
    @State private var store: LicenseStore
    @State private var router = AppRouter()
    private let backupService: any BackupService

    init() {
        #if DEBUG
        let repository = InMemoryLicenseRepository.sample()
        backupService = InMemoryBackupService(
            repository: repository,
            importLicenseCount: 5,
            importConflicts: Set(SampleData.licenses.prefix(2).map(\.id)))
        #else
        // No fake backup in release: it would report files that were never written.
        let repository = InMemoryLicenseRepository()
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
