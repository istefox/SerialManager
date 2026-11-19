# SPEC: Keychain serial store behind a protocol (ticket #3)

- Version: v2 (v1 approved 2026-11-19; v2 adds D5 and its consequences)
- Date: 2026-11-19
- Status: v2 approved by Stefano on 2026-11-19
- References: `docs/adr/0001-storage.md`, `docs/design/gui.md` ("Contract with the data layer"), tickets #3 and #4

## Goal

Serials are stored encrypted by the system in the macOS Keychain, never in clear text on disk.
This ticket delivers the storage primitive only: a `SerialStore` protocol, its Keychain
implementation and an in-memory fake. Ticket #4 (`LicenseRepository`) is its only consumer.

## Current state (baseline `61dd579`)

- No `SerialStore` and no Keychain code exist in `Sources/`.
- Serials live only in the dictionary inside `InMemoryLicenseRepository`; the app runs on fakes
  (`Sources/SerialManagerApp.swift`).
- The GUI depends on `LicenseRepository` (`Sources/Contract/LicenseContract.swift`) and never sees
  the serial storage.

## Decisions

- D1 (Stefano, 2026-11-19): deleting the serial of a UUID that has no Keychain item succeeds
  silently. There is no public "item not found" error.
- D2 (Stefano, 2026-11-19): the real Keychain implementation is verified by a manual smoke check
  run by QA, because no automated test may touch the real Keychain.
- D3 (ticket update, 2026-11-19): reading a UUID with no item returns nil; an error is thrown only
  for a real Keychain failure.
- D4 (ADR 0001, decision 3): the encrypted export is the only supported way to move serials
  between Macs. Keychain items are device-local and not synchronizable.
- D5 (Stefano, 2026-11-19, from plan v1 Q1): use the data protection keychain. The app is signed
  with the Apple Development identity of team T7H24G7BFW and carries a `keychain-access-groups`
  entitlement limited to its own group; Xcode registers the App ID `it.stefer.SerialManager` and a
  macOS development profile on that team. Reason: only the data protection keychain honours a
  `ThisDeviceOnly` accessibility class (TN3137); the build at `61dd579` is ad-hoc signed.

## Scope

In scope:
- `SerialStore` protocol: save, read and delete a serial by license UUID.
- Keychain implementation (generic password item).
- In-memory fake implementation.
- Unit tests for the fake's behaviour and for the Keychain error mapping.
- Signing and entitlement change in `Project.swift` required by D5, with the CLAUDE.md commands
  updated if they need `-allowProvisioningUpdates`.
- A `#if DEBUG` smoke harness for D2 and an ADR recording the keychain choice (D5) and its sources.

Out of scope (owned elsewhere):
- `LicenseRepository` implementation, consistency between entry and serial, empty-serial
  handling and wiring in `SerialManagerApp` (ticket #4).
- Any change to `LicenseRepository`, `InMemoryLicenseRepository` or the GUI.
- SwiftData model (ticket #2), export and import (tickets #8 to #10).
- iCloud Keychain sync and access groups shared with other apps.
- CI configuration (ticket #12), which must build with signing disabled after D5.

## Requirements

- R1. A `SerialStore` protocol offers three operations keyed by a license `UUID`: save a serial
  string, read the serial (returns `String?`), delete the serial. It is `Sendable` and usable from
  Swift 6 strict concurrency code. The Architect fixes the exact signatures (sync or async),
  consistent with `LicenseRepository`.
- R2. Saving a serial for a UUID that already has one replaces the value. Afterwards exactly one
  item exists for that UUID and a read returns the new value.
- R3. Reading a UUID that has no item returns nil and does not throw (D3).
- R4. Deleting a UUID that has no item succeeds without error (D1). Deleting an existing item
  removes it; a later read returns nil.
- R5. The serial round-trips unchanged, including non-ASCII characters and surrounding
  whitespace. The store does not trim, validate or interpret the value; empty-serial policy
  belongs to #4.
- R6. The Keychain implementation stores each serial as a generic password item with
  service = the app bundle identifier (`it.stefer.SerialManager`) and account = the UUID string.
  The service name is injectable, defaulting to the bundle identifier.
- R7. Keychain items live in the data protection keychain, are device-local
  (`WhenUnlockedThisDeviceOnly`) and not synchronizable (D4, D5). The app's signature carries the
  application identifier `T7H24G7BFW.it.stefer.SerialManager` and the `keychain-access-groups`
  entitlement; the attributes and sources are recorded in an ADR.
- R8. Keychain failures surface as a typed error that distinguishes at least: access denied
  (user or system refused access, or interaction not allowed), stored data that cannot be decoded,
  and any other unexpected failure carrying the underlying status code. "Item not found" is never
  thrown by read (R3) or delete (R4).
- R9. No error value, log message or description contains the serial.
- R10. An in-memory fake implements `SerialStore` with the same observable behaviour as R2 to R5,
  and can be told to fail with a given error so consumers (#4) can test failure paths.
- R11. No unit test touches the real Keychain. Tests added by this ticket use the fake; the
  Keychain error mapping is tested as a pure function from status code to error.
- R12. `SerialStore` stays inside the data layer: no view or GUI store references it, and
  `LicenseContract.swift` is unchanged.
- R13. The project builds and the full test suite passes with the commands in `CLAUDE.md`.
  No real serial, license key or personal data appears in code, tests, previews or docs.

## Acceptance examples

- A1 (R2). Save "TEST-AAAA-1111" for UUID u, then save "TEST-BBBB-2222" for u. Read u returns
  "TEST-BBBB-2222"; the store holds one item for u.
- A2 (R3). Read a fresh UUID v never saved: returns nil, no error.
- A3 (R4). Delete a fresh UUID v never saved: completes without error.
- A4 (R4). Save "TEST-CCCC-3333" for u, delete u, read u: returns nil.
- A5 (R5). Save "  TÉST-ÄÖÜ-✓  " for u, read u: returns exactly "  TÉST-ÄÖÜ-✓  ".
- A6 (R8). The mapping turns the access-denied and interaction-not-allowed statuses into the
  access-denied case, and an arbitrary unknown status into the unexpected case carrying that status.
- A7 (R10). A fake configured to fail with error E throws E on save, read and delete.
- A8 (R6, R7, D2). Manual smoke check on the real Keychain (below): one item, correct service and
  account, value replaced on second save, item gone after delete.

## Verification

| Req | Method |
|-----|--------|
| R1, R12 | Code review; `grep` shows no reference to `SerialStore` under `Sources/Views` or the GUI stores; `LicenseContract.swift` diff is empty |
| R2 to R5, R10 | Unit tests on the fake (A1 to A5, A7) |
| R8 | Unit tests on the status-to-error mapping (A6); code review that read and delete treat not-found as nil / success |
| R9 | Code review of error types and any logging |
| R11 | Code review: no test instantiates the Keychain implementation with a real Keychain |
| R6, R7 | Manual smoke check by QA (A8); `codesign -d --entitlements -` on the Debug app shows the application identifier and access group; code review of the item attributes against the ADR sources |
| R13 | `xcodebuild … build` and `xcodebuild … test` pass; reviewer check for real data |

### Manual smoke check (D2)

Run by QA on a Debug build, using a dedicated service name (`it.stefer.SerialManager.smoke`) so
production items are never touched. The `security` command-line tool targets the file-based
keychain (TN3137), so under D5 inspection is done by a `#if DEBUG` harness inside the signed app,
launched with a command-line flag, plus a visual check in Keychain Access ("Local Items"). The
harness is not a test, is in no scheme or test plan, and is absent from Release builds. It saves a
fake value for a fixed UUID, inspects (one item, service, account, not synchronizable,
`WhenUnlockedThisDeviceOnly`, app access group), saves a second fake value, inspects (still one
item, new value read back), deletes, inspects (no item), deletes again (no error). It prints item
attributes only, never the serial, exits 0 only when every step passes, and leaves no item behind.

## Open points for the Architect

- Exact protocol signatures (R1) and where the fake lives (`Sources/Fakes`, next to the existing
  fakes, or the test target), given that #4 tests need it.
- Resolved in plan v1: attributes and signing (D5), harness design. Remaining: the `Project.swift`
  change may conflict with ticket #2, in progress in another worktree.
