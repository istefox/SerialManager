import Foundation
import Observation

/// App-wide requests coming from menu commands, handled by the main window.
@MainActor
@Observable
final class AppRouter {
    enum Sheet: Identifiable, Equatable {
        case export
        case importBackup(URL)

        var id: String {
            switch self {
            case .export: "export"
            case .importBackup(let url): "import-\(url.path)"
            }
        }
    }

    enum Command: Equatable {
        case newLicense
        case editLicense
        case deleteLicense
        case copySerial
        case toggleSerial
    }

    /// One menu command; the id lets the same command fire twice in a row.
    struct Request: Equatable {
        let command: Command
        let id = UUID()
    }

    var sheet: Sheet?
    private(set) var request: Request?

    func send(_ command: Command) { request = Request(command: command) }

    func requestExport() { sheet = .export }

    func requestImport() {
        if let url = BackupFilePanels.chooseImportURL() { sheet = .importBackup(url) }
    }
}
