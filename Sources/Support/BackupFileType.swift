import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// Encrypted SerialManager backup (`.smbackup`), declared in the Info.plist via Project.swift.
    static let serialManagerBackup = UTType(exportedAs: "it.stefer.SerialManager.backup", conformingTo: .data)
}

/// System save and open panels for backup files.
@MainActor
enum BackupFilePanels {
    static func defaultFileName(on date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        return "SerialManager Backup \(day).smbackup"
    }

    /// Asks where to save a backup; nil when cancelled.
    static func chooseExportURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.serialManagerBackup]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a backup to import; nil when cancelled.
    static func chooseImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.serialManagerBackup]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
