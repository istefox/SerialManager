import AppKit
import Testing
@testable import SerialManager

/// Uses a private, uniquely named pasteboard: the user's clipboard is never touched.
@MainActor
struct ClipboardTests {
    private func withPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SerialManagerTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    @Test func copyMarksSecretAsConcealed() {
        withPasteboard { pasteboard in
            Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            #expect(pasteboard.string(forType: .string) == "ACME-0000-TEST-0000")
            #expect(pasteboard.types?.contains(Clipboard.concealedType) == true)
        }
    }

    @Test func clearsOnlyWhenUnchanged() {
        withPasteboard { pasteboard in
            let count = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            #expect(Clipboard.clearIfUnchanged(pasteboard, changeCount: count))
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func leavesNewerCopiesAlone() {
        withPasteboard { pasteboard in
            let count = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            pasteboard.clearContents()
            pasteboard.setString("something the user copied later", forType: .string)
            #expect(!Clipboard.clearIfUnchanged(pasteboard, changeCount: count))
            #expect(pasteboard.string(forType: .string) == "something the user copied later")
        }
    }

    // MARK: SM-05: orderly quit before the timer fires

    @Test func quitClearsTheStillOwnedCopyWhenClearingIsOn() {
        withPasteboard { pasteboard in
            let count = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            Clipboard.scheduleClear(after: 3600, changeCount: count, pasteboard: pasteboard)

            #expect(Clipboard.clearPendingOnTermination())
            #expect(pasteboard.string(forType: .string) == nil)
            // Nothing left to clear a second time.
            #expect(!Clipboard.clearPendingOnTermination())
        }
    }

    @Test func quitLeavesANewerCopyAlone() {
        withPasteboard { pasteboard in
            let count = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            Clipboard.scheduleClear(after: 3600, changeCount: count, pasteboard: pasteboard)
            pasteboard.clearContents()
            pasteboard.setString("something the user copied later", forType: .string)

            #expect(!Clipboard.clearPendingOnTermination())
            #expect(pasteboard.string(forType: .string) == "something the user copied later")
        }
    }

    @Test func quitKeepsTheCopyWhenClearingIsNever() {
        withPasteboard { pasteboard in
            let count = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            Clipboard.scheduleClear(after: 0, changeCount: count, pasteboard: pasteboard)

            #expect(!Clipboard.clearPendingOnTermination())
            #expect(pasteboard.string(forType: .string) == "ACME-0000-TEST-0000")
        }
    }

    @Test func aLaterNeverCopyIsNotWipedByAnEarlierTimer() {
        withPasteboard { pasteboard in
            let first = Clipboard.copySecret("ACME-0000-TEST-0000", to: pasteboard)
            Clipboard.scheduleClear(after: 3600, changeCount: first, pasteboard: pasteboard)
            let second = Clipboard.copySecret("ACME-1111-TEST-1111", to: pasteboard)
            Clipboard.scheduleClear(after: 0, changeCount: second, pasteboard: pasteboard)

            #expect(!Clipboard.clearPendingOnTermination())
            #expect(pasteboard.string(forType: .string) == "ACME-1111-TEST-1111")
        }
    }

    @Test func quitWithNothingPendingChangesNothing() {
        withPasteboard { pasteboard in
            pasteboard.setString("unrelated", forType: .string)
            #expect(!Clipboard.clearPendingOnTermination())
            #expect(pasteboard.string(forType: .string) == "unrelated")
        }
    }
}
