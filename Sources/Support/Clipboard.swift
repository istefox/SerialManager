import AppKit

/// Writes serials to the pasteboard and clears them later without touching newer copies.
@MainActor
enum Clipboard {
    /// Marker read by clipboard managers to skip secrets (nspasteboard.org convention).
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies a secret and returns the pasteboard change count after the write.
    @discardableResult
    static func copySecret(_ text: String, to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealedType)
        return pasteboard.changeCount
    }

    /// Clears the pasteboard only if nothing was copied since `changeCount`.
    @discardableResult
    static func clearIfUnchanged(_ pasteboard: NSPasteboard = .general, changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        return true
    }

    /// Clears the general pasteboard after `seconds`, if it still holds the copied serial.
    static func scheduleClear(after seconds: Int, changeCount: Int) {
        guard seconds > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            clearIfUnchanged(changeCount: changeCount)
        }
    }
}

/// User preference for clearing a copied serial.
enum ClipboardSettings {
    static let delayKey = "clipboardClearDelay"
    static let defaultDelay = 60
}
