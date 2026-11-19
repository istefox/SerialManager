import SwiftUI

/// File and License menus.
struct AppCommands: Commands {
    let store: LicenseStore
    let router: AppRouter
    let backupAvailable: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New License") { router.send(.newLicense) }
                .keyboardShortcut("n")
                .disabled(store.phase != .loaded)
            Divider()
            Button("Import Licenses\u{2026}") { router.requestImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!backupAvailable)
            Button("Export Licenses\u{2026}") { router.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!backupAvailable || store.licenses.isEmpty)
        }
        CommandMenu("License") {
            let noSelection = store.selectedLicense == nil
            Button("Edit License") { router.send(.editLicense) }
                .keyboardShortcut("e")
                .disabled(noSelection)
            Button("Copy Serial") { router.send(.copySerial) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(noSelection)
            Button("Show or Hide Serial") { router.send(.toggleSerial) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(noSelection)
            Divider()
            Button("Delete License\u{2026}") { router.send(.deleteLicense) }
                .disabled(noSelection)
        }
    }
}
