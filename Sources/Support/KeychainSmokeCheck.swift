#if DEBUG
import Foundation
import Security

/// Manual smoke check of `KeychainSerialStore` against the real Keychain (SPEC 0003, D2, A8).
///
/// Launched only from a Debug build with `--keychain-smoke-check`; it is not a test and is in no
/// scheme or test plan. It uses a dedicated service so production items are never touched, prints
/// item attributes and PASS/FAIL lines only (never a serial), always deletes its item before
/// exiting, and exits 0 only when every step passes.
///
/// Deadlock assumption: `runAndExit()` blocks the main thread on a semaphore while a detached task
/// runs the steps. That is safe only while the app target sets neither
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` nor the `NonisolatedNonsendingByDefault` feature
/// (neither is set today, SWIFT_VERSION 6.0): `KeychainSerialStore`'s nonisolated async methods then
/// run on the global executor, never on the blocked main thread.
enum KeychainSmokeCheck {
    static let argument = "--keychain-smoke-check"
    static let service = "it.stefer.SerialManager.smoke"
    static let accessGroup = "T7H24G7BFW.it.stefer.SerialManager"
    /// 00000000-0000-4000-8000-000000000003
    static let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x03))
    private static let valueA = "SMOKE-AAAA-1111"
    private static let valueB = "SMOKE-BBBB-2222"

    static func runAndExit() -> Never {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.passed = await run()
            done.signal()
        }
        done.wait()
        exit(outcome.passed ? 0 : 1)
    }

    private static func run() async -> Bool {
        let store = KeychainSerialStore(service: service)
        var runner = Runner()
        print("Keychain smoke check: service \(service), account \(id.uuidString)")

        await runner.step("delete (clean start)") { try await store.deleteSerial(for: id); return true }
        await runner.step("save A") { try await store.save(valueA, for: id); return true }
        await runner.step("inspect after save A") { inspect(store, expectedCount: 1) }
        await runner.step("read = A") { try await store.serial(for: id) == valueA }
        await runner.step("save B") { try await store.save(valueB, for: id); return true }
        await runner.step("inspect after save B") { inspect(store, expectedCount: 1) }
        await runner.step("read = B") { try await store.serial(for: id) == valueB }
        await runner.step("delete") { try await store.deleteSerial(for: id); return true }
        await runner.step("inspect after delete") { inspect(store, expectedCount: 0) }
        await runner.step("read = nil") { try await store.serial(for: id) == nil }
        await runner.step("delete again (no error)") { try await store.deleteSerial(for: id); return true }

        // Leave nothing behind, whatever happened above.
        try? await store.deleteSerial(for: id)
        print(runner.failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(runner.failures) failed)")
        return runner.failures == 0
    }

    /// Lists the items matching the store's own base query (attributes only, never data).
    private static func inspect(_ store: KeychainSerialStore, expectedCount: Int) -> Bool {
        var query = store.baseQuery(for: id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let items: [[String: Any]]
        switch status {
        case errSecSuccess:
            items = result as? [[String: Any]] ?? []
        case errSecItemNotFound:
            items = []
        default:
            print("  inspect: status \(status)")
            return false
        }

        print("  count \(items.count)")
        var matches = items.count == expectedCount
        for item in items {
            let service = item[kSecAttrService as String] as? String
            let account = item[kSecAttrAccount as String] as? String
            let sync = (item[kSecAttrSynchronizable as String] as? NSNumber)?.intValue ?? 0
            let accessible = item[kSecAttrAccessible as String] as? String
            let group = item[kSecAttrAccessGroup as String] as? String
            print("  svce \(service ?? "-") acct \(account ?? "-") sync \(sync) pdmn \(accessible ?? "-") agrp \(group ?? "-")")
            matches = matches
                && service == Self.service
                && account == id.uuidString
                && sync == 0
                && accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                && group == accessGroup
        }
        return matches
    }

    /// Runs and reports one step. Prints only the step name and its outcome, never a value read.
    private struct Runner {
        private(set) var failures = 0

        mutating func step(_ name: String, _ body: () async throws -> Bool) async {
            do {
                if try await body() {
                    print("PASS \(name)")
                } else {
                    failures += 1
                    print("FAIL \(name)")
                }
            } catch {
                // SerialStoreError carries no serial (R9), so it is safe to print.
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
    }

    private final class Outcome: @unchecked Sendable {
        var passed = false
    }
}
#endif
