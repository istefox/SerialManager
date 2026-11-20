# SPEC: License repository that keeps entry and serial consistent (ticket #4)

- Version: v1.1 (v1 approved 2026-11-20; v1.1 adds D9 and D10 from the plan's Q1 and Q2)
- Date: 2026-11-20
- Status: v1.1 approved by Stefano on 2026-11-20
- References: `docs/adr/0001-storage.md`, `docs/design/gui.md` ("Contract with the data layer"),
  `docs/specs/license-model.md` and `docs/specs/license-model-plan.md` (section "R7"),
  `docs/specs/0003-serial-store.md`, tickets #2, #3, #4, #10

## Goal

As a user I want an entry and its serial to stay consistent, so that I never find an entry
whose serial vanished because of a half-finished save, nor a serial left behind by a deleted
entry. A single `LicenseRepository` implementation is the only code that creates, updates and
deletes entries: it writes the metadata to SwiftData and the serial to the `SerialStore`.

## Current state (baseline `b8d6e14`, equal to `origin/main` on 2026-11-20)

- The contract is fixed by the GUI: `LicenseRepository`, `LicenseSummary` and `LicenseDraft` in
  `Sources/Contract/LicenseContract.swift`. Its signatures do not change in this ticket.
- `License` (`Sources/Model/License.swift`, ticket #2) is the SwiftData model, with a throwing
  `init`, a throwing `update(...)` and `@Attribute(.unique) id`. A duplicate insert is a silent
  upsert, not an error (license-model plan, section "R7").
- `SerialStore`, `KeychainSerialStore` and `InMemorySerialStore` exist (ticket #3).
  `SerialStoreError` has `.accessDenied`, `.undecodableData` and `.unexpected(status:)`.
- The app runs on `InMemoryLicenseRepository` in every configuration
  (`Sources/SerialManagerApp.swift`): a Release build loses every entry when it quits.
- The GUI already shows a missing serial: `LicenseStore.serial(for:)` maps nil to `.missing`
  and `SerialRow` shows "The serial for this license is missing from the Keychain." with an
  action to add one. The form refuses to save an empty serial when the current one could not
  be read (`LicenseFormModel.serialUnreadable`).
- `LicenseStore` turns every error into `error.localizedDescription` (lines 61 and 93).

## Decisions

- D1 (Stefano, 2026-11-20): deleting an entry deletes its serial first. If the serial cannot be
  deleted, the delete fails: the entry stays, its serial stays, and the user sees an error.
- D2 (Stefano, 2026-11-20): an update is all or nothing. If any part fails, the entry's fields
  and its serial are back to their previous values and the user sees an error.
- D3 (Stefano, 2026-11-20): no automatic clean-up of orphan Keychain items in this ticket. When a
  rollback itself fails, the repository reports the error and the case is documented. A sweep
  is a separate ticket, to be decided later.
- D4 (Stefano, 2026-11-20): when the Keychain denies access, the user sees a dedicated message
  instead of the generic one. Every other error keeps the generic message.
- D5 (ticket #4 update, approved by Stefano 2026-11-19): before inserting an entry with a given
  id, the repository looks that id up and decides explicitly. It never relies on the store to
  report the conflict, because the store overwrites silently.
- D6 (ticket #4 update, 2026-11-19, GUI contract): `update` with an empty serial deletes the
  Keychain item; `serial(for:)` returns nil when the item is missing and throws only for a real
  Keychain failure; `fetchAll()` order is free. Release builds use the real implementation,
  Debug builds and previews stay on the fakes.
- D7 (Lead, constraint): an entry created with an empty serial is valid and has no Keychain item.
  The repository stores the serial exactly as it receives it; trimming stays in the GUI
  (`LicenseDraft.normalized`).
- D8 (Lead, constraint): the app never falls back silently to a non-persistent store. If the
  persistent `ModelContainer` cannot be opened, the user sees an error instead of an empty
  app that discards what they type.
- D9 (Stefano, 2026-11-20, plan Q1): when the stored serial cannot be decoded
  (`SerialStoreError.undecodableData`), update and delete still go ahead, so a corrupted item
  never blocks editing or deleting its entry. If the SwiftData step then fails, the previous
  serial cannot be restored: this is a failed rollback under D3, not a breach of D2. An
  `.accessDenied` or `.unexpected` read still stops the operation before any write.
- D10 (Stefano, 2026-11-20, plan Q2): the startup failure of D8 also gets a dedicated message.
  D4 now covers two cases: Keychain access denied and library unavailable.

## Scope

In scope:
- A SwiftData plus `SerialStore` implementation of `LicenseRepository`.
- Rollback on partial failure for create, update and delete.
- The explicit id check before insert (D5), applied in `create`.
- The dedicated access-denied message (D4), in whatever layer the plan picks, including the
  catch sites in `Sources/Store/LicenseStore.swift` if needed.
- Wiring in `SerialManagerApp.init()` for Release builds, with the `ModelContainer` created there.
- Unit tests with an in-memory SwiftData container and an in-memory serial store.
- Manual checks against the real Keychain listed under "Verification".
- Updating `docs/design/gui.md` "Known gaps" once Release builds persist data.

Out of scope:
- Any change to the signatures in `Sources/Contract/LicenseContract.swift`.
- Inserting an entry with a caller-supplied id and the skip or replace conflict policy: that is
  import (#10). This ticket only guarantees that `create` never overwrites an existing entry.
- Export and import (#9, #10). `UnavailableBackupService` stays in Release.
- A sweep of orphan Keychain items (D3).
- Schema migrations: there is no persisted data yet, so the first Release build starts empty.
- Changes to the fakes' behaviour used by Debug builds and previews.

## Requirements

- R1. Create saves both. `create(_:)` with a valid draft and a non-empty serial persists one
  `License` with the draft's fields and a new id, saves the serial under that id, and returns a
  `LicenseSummary` matching the stored entry (`createdAt == updatedAt`).
- R2. Create with an empty serial persists the entry and writes nothing to the serial store;
  `serial(for:)` then returns nil.
- R3. Create is atomic. If saving the serial fails, no `License` with the new id remains in the
  store and the error is thrown. If persisting the entry fails after the serial was saved, the
  serial is deleted and the error is thrown.
- R4. Create never overwrites (D5). Before inserting, the repository fetches the new id. If an
  entry with that id exists, `create` throws a dedicated error and changes nothing: the existing
  entry's fields, `createdAt` and serial are unchanged.
- R5. Create and update reject a blank product name with `LicenseValidationError.emptyProductName`
  and write nothing to either store.
- R6. Update replaces every editable field, sets `updatedAt`, keeps `id` and `createdAt`, and
  returns the updated summary. A non-empty serial replaces the stored one; an empty serial
  deletes the Keychain item (D6).
- R7. Update of an unknown id throws a not-found error and writes nothing to either store.
- R8. Update is all or nothing (D2). If the serial write or delete fails, the entry's fields and
  `updatedAt` are back to their previous values in the persistent store and the error is thrown.
  If persisting the entry fails after the serial changed, the previous serial is restored (or
  deleted again if there was none) and the error is thrown.
- R9. Delete removes both (D1). `delete(id:)` deletes the serial first, then the entry. If the
  serial delete fails, the entry is not deleted and the error is thrown. If deleting the entry
  fails after the serial was deleted, the previous serial is restored and the error is thrown.
- R10. Delete of an unknown id succeeds and still asks the serial store to delete any item for
  that id.
- R11. Missing serial is handled (ticket criterion). `fetchAll()` returns every entry, whether or
  not its serial exists, and never reads the Keychain. `serial(for:)` returns nil when the item
  is missing and throws only the serial store's errors. No path crashes on a missing item, and
  the GUI's existing "missing serial" state is shown.
- R12. Failed rollback (D3, D9). If a compensating step fails, or the previous serial was
  unreadable and cannot be restored, the repository throws the original
  error, does not crash, and the code documents that an orphan serial or a stale serial may
  remain. No clean-up sweep runs.
- R13. Access denied (D4). When a repository call fails because the serial store reports
  `.accessDenied`, the message the user sees is a dedicated English text, proposed:
  "Keychain access was denied. Try again, or check the Keychain permissions for SerialManager."
  The exact wording is the Frontend's call. When the library cannot be opened (R14, D10), the
  failure state shows a dedicated English text, proposed: "SerialManager couldn't open its
  library file. Quit and reopen the app; if this keeps happening, check the disk." Other errors
  keep the current generic message.
- R14. Wiring (D6, D8). A Release build creates a persistent `ModelContainer` for `License` in
  `SerialManagerApp.init()` and uses the real repository with `KeychainSerialStore`. Debug builds
  and previews keep `InMemoryLicenseRepository`. If the container cannot be created, the app
  shows an error and does not run on an in-memory store.
- R15. Tests. Unit tests cover R1 to R12 with an in-memory SwiftData container and an in-memory
  serial store; no automated test touches the real Keychain. Reads that check persistence go
  through a new `ModelContext` after `save()`, as in `Tests/LicenseModelTests.swift`.

## Acceptance examples

Sample values are fake: product "Example App", serial `ACME-0000-TEST-0000`.

- A1 (R1). Create "Example App" with serial `ACME-0000-TEST-0000`. A new context fetches one
  entry named "Example App"; the serial store holds `ACME-0000-TEST-0000` under its id.
- A2 (R2). Create "Example App" with serial `""`. One entry exists; the serial store has no
  item; `serial(for:)` returns nil.
- A3 (R3). Serial store save fails with `.accessDenied`. `create` throws; a new context fetches
  zero entries; the serial store holds zero items.
- A4 (R4). Entry U "Example App" exists with serial S. `create` is driven to generate id U and
  name "Other App". It throws the duplicate error; U is still "Example App" with its original
  `createdAt`; the serial is still S.
- A5 (R6). Entry U with serial S. Update with serial `""`: the item for U is gone, the entry
  stays, `updatedAt` changed, `createdAt` did not.
- A6 (R8). Entry U "Example App" with serial S. Update to "Renamed App" with serial S2 while
  the serial save fails. `update` throws; a new context fetches U named "Example App" with the
  old `updatedAt`; the serial is S.
- A7 (R9). Entry U with serial S, serial delete fails. `delete` throws; U is still fetched and
  the serial is S. With no failure, `delete` leaves zero entries and zero items.
- A8 (R11). Entry U with no Keychain item. `fetchAll()` returns U; `serial(for: U)` returns nil;
  the detail view shows the missing-serial state.
- A9 (R13). Serial read fails with `.accessDenied`: the detail view shows the dedicated message.
  A failure with `.unexpected(status:)` shows the generic message.

## Verification

| Requirement | How |
| --- | --- |
| R1 to R10, R12 | Unit tests (Swift Testing), in-memory SwiftData container, a serial store double that can fail per operation |
| R11 | Unit test for the repository; existing `SerialRow` "missing" preview and `LicenseStore` test for the GUI side |
| R13 | Unit test on the error-to-message mapping; QA reads it in a preview or in the app |
| R14 | Code review of `SerialManagerApp.init()`; QA runs a Release build, adds an entry, quits, relaunches and finds it with its serial |
| R15 | CI green (`Build and test`), plus a check that no test instantiates `KeychainSerialStore` with the real Keychain |

Manual checks against the real Keychain (from the #3 code review, F4), on a Release build signed
with team T7H24G7BFW: create, read, update and delete an entry whose serial is non-ASCII
(`ÀÉÎ-ñ-測試-🔑`), one with surrounding spaces in the field (the GUI trims them before saving,
so the stored value has none), and one with an empty serial (no Keychain item). A clone without
that team builds and tests with `CODE_SIGNING_ALLOWED=NO` (F5) but cannot run these checks.

## Open points for the Architect

- Concurrency model of the repository (`@ModelActor` or main actor), given that `ModelContext`
  is not `Sendable` and the protocol is `Sendable`.
- How tests generate a chosen id for A4 (an injectable id source) and how they force a SwiftData
  save failure for the second half of R3, R8 and R9, if that is feasible without touching the
  real store. If a case cannot be forced, say so in the plan and propose another check.
- `InMemorySerialStore` fails every operation at once. The per-operation double needed by the
  rollback tests belongs in `Tests/`, unless changing the shared fake is clearly better.
- Where the D4 message lives (a `LocalizedError` conformance or a mapping in `LicenseStore`) and
  how errors stay unwrapped so the mapping sees `.accessDenied`.
- Which file the Frontend owns for R13 and how the Backend's error types reach it.
