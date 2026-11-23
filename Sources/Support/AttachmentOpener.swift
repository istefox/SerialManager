import AppKit
import Foundation

/// Hands a decrypted copy of an attachment to another application (SPEC 0018, R19).
///
/// The stored encrypted file is never passed out and never modified by another app: every Open
/// writes a fresh plaintext copy, under the attachment's original file name so the receiving app
/// sees the extension it expects, inside its own UUID subfolder of `directory`. A subfolder per
/// open means two files with the same name never collide, and a vendor installer that moves or
/// consumes the copy harms nothing.
///
/// `directory` is injectable and sits under the system temporary directory, well away from the
/// Attachments folder: Debug and Release share one bundle identifier, so a test must never be able
/// to delete anything the real app stores (R9, A18).
@MainActor
final class AttachmentOpener {
    /// Where the decrypted copies live. Only this feature writes here, which is what makes the
    /// blanket cleanup safe.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "OpenedAttachments", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let openFile: (URL) -> Bool

    /// - Parameters:
    ///   - directory: the root of the decrypted copies. Everything in it is deleted by `cleanUp`.
    ///   - openFile: asks the system to open the copy. Injected so a test never launches an app.
    init(
        directory: URL = AttachmentOpener.defaultDirectory,
        openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.directory = directory
        self.openFile = openFile
    }

    /// Writes `data` under the attachment's name and asks the system to open it.
    ///
    /// - Returns: the copy that was handed over, so a caller can say where it went.
    /// - Throws: `AttachmentError.openFailed` when no application took the file. A write failure
    ///   throws the underlying `CocoaError`; neither message carries the plaintext.
    @discardableResult
    func open(_ attachment: AttachmentSummary, data: Data) throws -> URL {
        let url = try write(attachment, data: data)
        guard openFile(url) else {
            throw AttachmentError.openFailed(fileName: attachment.fileName)
        }
        return url
    }

    /// The copy, without opening it. Separate so `open` stays readable and a test can assert the
    /// layout without the system call.
    func write(_ attachment: AttachmentSummary, data: Data) throws -> URL {
        // The name is validated on the way in and on the way out of a backup
        // (`AttachmentRecord.isValidFileName`), so it cannot carry a path component. Checked again
        // here because this is the one place that turns a stored name into a real path.
        let name = AttachmentRecord.isValidFileName(attachment.fileName)
            ? attachment.fileName
            : attachment.id.uuidString
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes every decrypted copy. Called when the app quits and again at the next launch, in
    /// case the app was killed: a plaintext copy must not outlive the session that made it.
    ///
    /// Never throws: nothing here is worth failing a launch or a quit over.
    nonisolated static func cleanUp(directory: URL = AttachmentOpener.defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Instance form, so a view holding an opener with an injected directory cleans up its own.
    func cleanUp() {
        Self.cleanUp(directory: directory)
    }
}
