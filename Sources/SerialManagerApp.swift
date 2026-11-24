import AppKit
import SwiftUI

@main
struct SerialManagerApp: App {
    // Release builds use the persistent library: entries in SwiftData, serials in the Keychain
    // (LicenseLibrary). If the library cannot be opened, the window shows its failure state
    // instead of running on an in-memory store. Export writes the real encrypted backup and
    // Import restores it (EncryptedBackupService, ADR 0002): Import is enabled also with an
    // empty library, the new-Mac case (#10). Debug builds and previews run on in-memory fakes
    // with fake sample data.
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
        // No fake backup in release: the real service encrypts the library into one file.
        let repository = LicenseLibrary.makeRepository()
        backupService = EncryptedBackupService(repository: repository)
        #endif
        _store = State(initialValue: LicenseStore(repository: repository))
        // Defensively at launch, in case a previous run was killed before it could clean up: a
        // decrypted copy of an attachment must not outlive the session that made it (R19). Safe
        // as a blanket delete because only this feature writes in that directory.
        AttachmentOpener.cleanUp()
        // And at quit, which is the normal case. `onDisappear` on the window is not reliable for
        // termination, so this listens for the notification AppKit always posts.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            AttachmentOpener.cleanUp()
            // The notification is delivered on the main queue, so this is the main actor.
            MainActor.assumeIsolated { _ = Clipboard.clearPendingOnTermination() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, router: router, backupService: backupService)
        }
        .commands {
            AppCommands(
                store: store,
                router: router,
                exportAvailable: backupService.isExportAvailable,
                importAvailable: backupService.isImportAvailable)
        }

        Settings {
            SettingsView()
        }
    }
}
