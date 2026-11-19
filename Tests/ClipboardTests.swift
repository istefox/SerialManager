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
}
