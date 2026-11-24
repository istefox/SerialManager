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

    /// The copy that a timed clear is still waiting on: the pasteboard it was made on, its change
    /// count, and the timer. Nil when no timed clear is pending (nothing copied, the timer fired,
    /// or the last copy was made with clearing off).
    private struct PendingClear {
        let pasteboard: NSPasteboard
        let changeCount: Int
        let timer: Task<Void, Never>
    }

    private static var pending: PendingClear?

    /// Clears `pasteboard` after `seconds`, if it still holds the copied serial.
    ///
    /// A delay of 0 or less means Never: it also forgets an earlier pending clear, so quitting
    /// later cannot wipe a copy made with clearing off.
    static func scheduleClear(
        after seconds: Int, changeCount: Int, pasteboard: NSPasteboard = .general
    ) {
        pending?.timer.cancel()
        pending = nil
        guard seconds > 0 else { return }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            clearIfUnchanged(pasteboard, changeCount: changeCount)
            pending = nil
        }
        pending = PendingClear(pasteboard: pasteboard, changeCount: changeCount, timer: timer)
    }

    /// Orderly quit: the in-process timer dies with the app while the pasteboard keeps its content,
    /// so a copy still waiting on its timer is cleared now. Only the app's own entry goes, and
    /// only when clearing was on for that copy (SPEC 0007, R3). Force quit and crash are not
    /// covered: nothing runs.
    @discardableResult
    static func clearPendingOnTermination() -> Bool {
        guard let pending else { return false }
        pending.timer.cancel()
        self.pending = nil
        return clearIfUnchanged(pending.pasteboard, changeCount: pending.changeCount)
    }
}

/// User preference for clearing a copied serial.
enum ClipboardSettings {
    static let delayKey = "clipboardClearDelay"
    static let defaultDelay = 60
}
