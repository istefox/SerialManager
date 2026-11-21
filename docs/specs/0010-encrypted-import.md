# SPEC: Import of the encrypted backup (backlog #10)

- Version: v2 (v1 approved 2026-11-21; v2 replaces the v1.1 draft)
- Date: 2026-11-21
- Status: v1 approved by the owner on 2026-11-21 (D1 to D6 included); D7 and the R5 wording
  (v1.1) confirmed by the owner on 2026-11-21; v2 (revised D5, D7, R17) confirmed by the owner
  on 2026-11-21
- Clarification after confirmation (2026-11-21, PLAN review round 4, no change in behaviour):
  A17 reads "at least once" instead of "once", because `cancelImport()` is idempotent and the
  plan cancels again if the sheet closed while `prepareImport` ran; A17 also states that moving
  through the steps records no cancel.
- Changes v1 -> v2 (2026-11-21): D5 revised by the owner's decision (relayed by the
  chief-of-staff): cancelling the import drops the decrypted payload at once through a new
  `BackupService.cancelImport()` (R11, new R17, A15 to A17, R15, R16, verification). From PLAN
  review #10: R5 reworded (read-only lookup of the library's ids); D7 added and R12 narrowed
  (repository writes may run on the main queue). Current state and Architect notes refreshed
  to baseline `4efff0c`. Nothing else changed.
- Related: `docs/adr/0002-backup-format.md` (format, check order, error mapping, payload, apply
  rules: normative), `docs/specs/0009-encrypted-export.md`, `docs/specs/license-model-plan.md`
  (section "R7"), `docs/design/gui.md` ("Import"), `Sources/Contract/LicenseContract.swift`

## Goal

The owner restores a backup made by Export on a new Mac (or on the same one) and finds every
license and its serial again. The import never leaves the library in an unknown state: a wrong
password or a bad file changes nothing, and existing licenses are never overwritten unless the
owner chose Replace.

## Current state (evidence, 2026-11-21, worktree `feature-encrypted-import` at `4efff0c`, equal to `origin/main`, PR #14 merged)

Already in place:

- File > Import Licenses... (`Cmd+Shift+I`) in `Sources/AppCommands.swift`, enabled from
  `BackupService.isImportAvailable`; `AppRouter.requestImport()` shows the open panel
  (`BackupFilePanels.chooseImportURL()`) and opens the import sheet.
- `Sources/Views/ImportView.swift` and `ImportModel` (`Sources/Store/BackupModels.swift`):
  password, inline `BackupError` messages with the password kept for a retry, conflict step
  with Skip (default) / Replace applied to all conflicts, Importing, summary
  (Imported / Replaced / Skipped), Failed with a message. Without conflicts the import is
  applied right away. After a successful apply the model reloads the list (`store.load()`).
- Contract: `prepareImport(from:password:) -> ImportPreview(fileURL, licenseCount,
  conflictingIDs)`, `applyImport(_:policy:) -> ImportSummary(imported, replaced, skipped)`,
  `BackupError` (`wrongPassword`, `corruptedFile`, `unsupportedVersion`).
- `EncryptedBackupService` (#9) writes the v1 format; both import methods throw "not
  available" and `isImportAvailable` is false, so Import is disabled in Release.
  `BackupFormat`, `BackupKeyDerivation` and `BackupPayload` (encoder, three-digit date decoder)
  exist and are reusable.
- Debug builds and previews use `InMemoryBackupService` (scripted, reads no file).

Missing:

- The reader: header parsing, bounds, check order and error mapping of ADR 0002 sections 4
  and 5, decryption, payload validation.
- A way to write a license with a given `id`, `createdAt` and `updatedAt`: today
  `LicenseRepository.create` generates a new id and uses the current time, and `update` sets
  `updatedAt` to now. The repository protocol, `SwiftDataLicenseRepository` and the in-memory
  fake need an import path.
- Release enabling (`isImportAvailable == true`), the partial-failure message, tests.

## Decisions

From ADR 0002 and the ticket updates of 2026-11-19 (not reopened here): check order and error
mapping of ADR section 5; import bounds of section 4; any non-empty password, NFC-normalized;
`""` serial equals null; an import never deletes a Keychain item that existed before it;
`.replace` with a null serial replaces only the metadata; no conflict with a null serial
creates the entry with no Keychain item; two licenses with the same `id` in the file are
`corruptedFile`; unknown keys ignored; dates with or without fractional seconds; conflicts
found by looking the id up before inserting, never through the SwiftData upsert; tests derive
at the real 600,000 iterations and compare dates at millisecond precision.

Taken on 2026-11-21:

- D1: if a write fails partway through `applyImport` (SwiftData or Keychain error on license
  k of n), the import stops at that license. Licenses already written stay written; nothing
  after k is attempted. The sheet shows Import Failed with a message that says how many
  licenses were imported and replaced before the stop, followed by the underlying error's
  message. Running the same import again is safe: the licenses already written become
  conflicts. (Answer given by the owner's personal assistant under the owner's standing rule
  "pick the recommended option"; the owner confirms or changes it by approving this SPEC.)

Proposed by the PM, accepted or changed by approving this SPEC:

- D2: a license whose `productName` is empty or only whitespace makes the whole file
  `corruptedFile` at `prepareImport` (validation step 6), so it cannot fail later in the
  middle of an apply. This extends the list of ADR 0002 step 6; ADR text stays as is and this
  SPEC records the extension.
- D3: imported values are stored exactly as they are in the file (no trimming), including
  `createdAt` and `updatedAt`, both for a new license and for a replaced one. A restore keeps
  the original dates.
- D4: each license is applied as one unit. If the metadata write fails after the serial was
  written, the step undoes its own serial write: for a new license it removes the item it just
  created, for a replaced one it restores the previous value (the same compensation the
  repository already uses in `create` and `update`). The "never deletes a Keychain item" rule
  protects items that existed before the import; it is not broken by undoing an item the same
  step just created. A failed compensation can leave an orphan serial, as for `create` today.
- D5 (revised in v2 by the owner, 2026-11-21): the decrypted payload is kept by the service
  only between `prepareImport` and the first of: the next `applyImport`, the next
  `prepareImport`, or `cancelImport()`. Cancelling the import drops it at once: the contract
  gains `BackupService.cancelImport()`, which the import sheet calls on Cancel and whenever the
  sheet closes before `applyImport` started. `applyImport` drops it whether it succeeds or
  fails. It is never written to disk or logged. (v1 text: on cancel the payload stayed in
  memory until the next `prepareImport`, accepted limit, no contract change.)
- D6: verification split. Debug builds and previews stay on the in-memory fakes. The real
  import is proven by automated tests on `EncryptedBackupService` with a real SwiftData
  repository on an in-memory or temporary store and the in-memory serial store, never the real
  Keychain. The Release behaviour (menu enabled, real Keychain) is covered by an owner-run
  Release checklist that QA prepares; QA's verdict covers the automated tests and code review,
  and lists the checklist as owner-run.

Added in v1.1 (PLAN review #10), accepted or changed by confirming v1.1:

- D7: in Release the license repository is created on the main thread at launch, so its
  SwiftData writes may run on the main queue (known since plan 0004, which accepted the same
  cost for the form). The import keeps reading, key derivation and decryption off the main
  thread (the slow part, verified by a test); the per-license writes (one small save each) may
  run on the main queue. Moving the repository off the main thread is a separate change to
  `LicenseLibrary`, out of scope here.

## In scope

- `prepareImport` and `applyImport` in `EncryptedBackupService`, per ADR 0002 sections 4, 5,
  6 and 8 (import side) and the decisions above.
- The repository import path (protocol, SwiftData implementation, in-memory fake).
- The partial-failure error (D1) with English and Italian messages.
- `ImportModel.apply`: reload the list after a failed apply too, so partially imported
  licenses appear.
- `isImportAvailable == true` for the real service; Release wiring comment in
  `SerialManagerApp`.
- `BackupService.cancelImport()` (D5): the contract, the real service, every other conformer
  (in-memory fake, unavailable service, test doubles) and the import sheet's calls.
- Test fixture: a known v1 backup file built from fake data and a fake password.
- Tests, `docs/design/gui.md`, `Resources/Localizable.xcstrings`, the owner-run Release
  checklist (`docs/qa/`).

## Out of scope

- Any change to the file format, crypto parameters, bounds or check order of ADR 0002.
- A per-license conflict choice, merging fields, a list of conflicting names, a per-license
  progress bar, cancelling an import that is already applying.
- Opening a backup by double-clicking it in Finder, importing CSV or other apps' formats.
- An all-or-nothing rollback of the whole import (rejected by D1).
- Changing the import sheet layout or its states beyond the D1 message and the reload.

## Requirements

- R1. Check order and errors: `prepareImport` runs the six steps of ADR 0002 section 5 in
  order and stops at the first failure: first 10 bytes (fewer, or wrong magic, or version 0 ->
  `corruptedFile`; version above 1 -> `unsupportedVersion`, no key derived), then file size
  above 67,108,864 bytes -> `corruptedFile`, then the rest of the header (unknown KDF or
  cipher id, iterations outside [600,000, 10,000,000], salt length outside [16, 64], file cut
  inside the header, file size not `33+S+L+16` -> `corruptedFile`), then derivation and
  AES-GCM opening with the header as associated data (authentication failure ->
  `wrongPassword`), then payload validation (R2). The first 10 bytes are read without reading
  the whole file.
- R2. Payload validation: decrypted bytes that are not UTF-8 JSON, a missing required key, a
  wrong type, an invalid UUID or date, two licenses with the same `id`, or an empty or
  whitespace-only `productName` (D2) -> `corruptedFile`. Unknown keys are ignored. Dates are
  accepted with three fractional digits and without fractional seconds.
- R3. Password: any non-empty password is accepted by the service; it is NFC-normalized and
  UTF-8 encoded before derivation, as in export.
- R4. Nothing changes before apply: `prepareImport` never writes to the library or the
  Keychain, whatever its outcome. Any failure in `prepareImport` leaves the library exactly as
  it was.
- R5. Preview: on success `ImportPreview.licenseCount` is the number of licenses in the file
  and `conflictingIDs` the ids that already exist in the library, found by a read-only lookup
  of the library's ids (no write, no insert).
  The decrypted payload is kept for the next `applyImport` (D5).
- R6. Apply without conflict: a license whose id does not exist is created with the file's
  `id`, every metadata field and `createdAt`/`updatedAt` as in the file (D3); its serial is
  saved in the Keychain when non-null and non-empty; with a null or `""` serial no Keychain
  item is created. Counted as `imported`.
- R7. Apply with conflict, `.skip`: the local license and its Keychain item are left
  untouched, every field including `createdAt` and `updatedAt`. Counted as `skipped`.
- R8. Apply with conflict, `.replace`: every metadata field, `createdAt` and `updatedAt` are
  replaced with the file's values; the Keychain item is replaced when the file's serial is
  non-null and non-empty, and kept unchanged otherwise. Counted as `replaced`. The replacement
  is an explicit lookup and update, never an insert that relies on the SwiftData upsert.
- R9. Conflicts at apply time: `applyImport` looks every id up again when it runs, so the
  summary reflects the library at that moment. On success `imported + replaced + skipped ==
  licenseCount`. An empty backup succeeds with `0 / 0 / 0`.
- R10. Partial failure (D1, D4): a write error on license k stops the apply; licenses before
  k keep their changes, license k leaves no partial change (D4), licenses after k are not
  touched. `applyImport` throws an error whose user-facing message states the number of
  licenses imported and replaced before the stop, followed by the underlying error's message.
  `ImportModel` shows it through `Phase.failed` and reloads the list.
- R11. Stale or missing preview: `applyImport` called with no pending payload, or with a
  preview whose `fileURL` does not match the pending one, throws a generic (non-`BackupError`)
  error and writes nothing. After any `applyImport` or `cancelImport()` the pending payload is
  dropped (D5).
- R12. Off the main actor: reading, derivation and decryption do not run on the main thread;
  the repository writes may run on the main queue (D7). The sheet stays in Checking or
  Importing meanwhile.
- R13. Secrets hygiene: the password, the derived key, the decrypted payload and any serial
  are never persisted outside the library and the Keychain, logged, or included in an error
  message.
- R14. Release wiring: `EncryptedBackupService.isImportAvailable` is true; in Release, File >
  Import Licenses... is enabled, also with an empty library (the new-Mac case). Debug builds
  and previews stay on the fakes (D6).
- R15. Docs and strings: `docs/design/gui.md` (Import, Known gaps, contract) describes the real
  import, the partial-failure message, the enabled menu and `cancelImport()` on Cancel and close; every new user-facing string has English
  and Italian in `Resources/Localizable.xcstrings`.
- R16. Tests (Swift Testing, CI): automated tests cover R1 to R11 with fake data and fake
  passwords only, never the real Keychain, including: a known fixture file (fake password,
  salt, nonce and payload) that decrypts into the expected licenses; the export then import
  round trip into an empty library; `.skip` on an existing id leaving every field unchanged,
  `createdAt` included; dates compared at millisecond precision; R17 on the real service and on
  the in-memory fake. No test is disabled.
- R17. Cancel (D5): `BackupService.cancelImport()` drops the pending payload, if any. It is
  idempotent, never throws, writes nothing to the library or the Keychain, and is safe with no
  import in progress. After it, `applyImport` with the earlier preview fails as in R11. A
  `prepareImport` already running when `cancelImport()` is called leaves no pending payload
  once it returns, whatever it returns. `cancelImport()` does not stop or change an
  `applyImport` already running (cancelling an apply stays out of scope). The import sheet
  calls it on Cancel (password, checking and conflict steps) and when the sheet closes in any
  state before `applyImport` started; the in-memory fake implements the same rule.

## Acceptance examples

All values are fake.

- A1 (R1, R2, R16). The committed fixture, made with password `sample-backup-pass`, fixed
  salt and nonce, holding "Sample Editor" (serial `FAKE-0000-0000-0000`, `purchaseDate`
  null) and "Sample Viewer" (serial null): `prepareImport` into an empty library returns
  `licenseCount 2`, no conflicts; `applyImport` returns `2 / 0 / 0`; the library holds both
  with every field and both dates equal at millisecond precision; the Keychain fake holds
  `FAKE-0000-0000-0000` for the first id and no item for the second.
- A2 (R6, R9, R16). Round trip: export a library of three fake licenses (one with no serial),
  import the file into a new empty library with the same password: three licenses with the same
  ids, fields, dates and serials; summary `3 / 0 / 0`.
- A3 (R1, R4). Same fixture, password `sample-backup-paSS`: `wrongPassword`; the library and
  the Keychain fake are unchanged (same licenses, same serials).
- A4 (R1, R4). Each corruption gives `corruptedFile` and changes nothing: 9-byte file; magic
  `SMBACKUQ`; version `0`; KDF id `0x02`; iterations 599,999 and 10,000,001; salt length 15
  and 65; one byte removed from the end; one byte appended; a file above 64 MiB.
- A5 (R1). Version `2` with an otherwise invalid header and a size above 64 MiB:
  `unsupportedVersion`, and no key is derived.
- A6 (R2). Payloads sealed with the right password: two licenses with the same id; a missing
  `createdAt`; `id` `"not-a-uuid"`; `productName` `"   "`; not JSON: all `corruptedFile`. A
  payload with an extra key `"color": "red"` and dates without fractional seconds imports.
- A7 (R3). A fixture made with `cafe\u{301}-sample-pw` opens with `caf\u{E9}-sample-pw`.
- A8 (R7, R16). The library holds license X (`createdAt` 2026-01-01T09:00:00.000Z, serial
  `FAKE-LOCAL-0001`); the file holds X with another product name, other dates and serial
  `FAKE-FILE-0001`. Preview: one conflict. `.skip`: X keeps every local field, both dates and
  `FAKE-LOCAL-0001`; summary `0 / 0 / 1` plus the others imported.
- A9 (R8). Same as A8 with `.replace`: X has the file's fields and dates and serial
  `FAKE-FILE-0001`; summary counts it as replaced. Same with the file's serial null or `""`:
  X has the file's fields and still `FAKE-LOCAL-0001`.
- A10 (R6). No conflict, file serial `""`: the license is created and the Keychain fake has no
  item for it.
- A11 (R10). Five licenses in the file, the serial store fails on the third save: the first two
  are in the library with their serials, the third and later are absent, no serial is left
  for the third; the error message says 2 licenses imported and 0 replaced before the stop and
  includes the serial store's message; after the failure the list shows the two licenses.
  Running the same import again: preview shows 2 conflicts.
- A12 (R9). Empty `licenses` array: preview `0`, no conflicts, summary `0 / 0 / 0`.
- A13 (R11). `applyImport` without a previous `prepareImport`, and a second `applyImport`
  with the same preview: generic error, nothing written.
- A15 (R17). Prepare the A1 fixture, then `cancelImport()`, then `applyImport` with that
  preview: generic error, the library and the Keychain fake are unchanged. Calling
  `cancelImport()` twice, or with no import prepared, does nothing and does not throw. Same on
  the in-memory fake.
- A16 (R17). `cancelImport()` called while `prepareImport` of the A1 fixture is running (the
  `deriveKey` seam holds the derivation until the cancel is issued): after `prepareImport`
  returns, `applyImport` with its preview fails as in R11 and nothing is written.
- A17 (R17). `ImportModel`/sheet: Cancel at the password, checking and conflict steps, and
  closing the sheet before Import, each call `cancelImport()` at least once on the service
  (recorded by the fake; a second call while `prepareImport` is still running is allowed, since
  the call is idempotent); no `cancelImport()` is recorded once `applyImport` has started, nor
  while moving through the steps password, checking, conflicts and importing. Done and Close
  after `applyImport` do not need it.
- A14 (R14). Release build with an empty library: File > Import Licenses... enabled; importing
  the A1 fixture with its password shows "Imported: 2", and the detail of "Sample Editor"
  reveals its serial (owner-run checklist).

## Verification

| Req | Method |
| --- | --- |
| R1, R2, R3, R4 | Unit tests on the real service with crafted files in a temporary directory (A3 to A7), checking the library and serial store snapshots before and after |
| R5, R6, R7, R8, R9 | Unit tests on the real service with a SwiftData repository on a test store and the in-memory serial store (A1, A2, A8, A9, A10, A12) |
| R10 | Unit test with a serial store fake that fails on the k-th save (A11), plus an `ImportModel` test that a failed apply reloads the list |
| R11 | Unit tests (A13) |
| R17 | Unit tests on the real service (A15, A16) and on the in-memory fake (A15); `ImportModel` or view test with the recording fake (A17); code review of the sheet's close path |
| R12, R13 | Code review; R12 also by a test that records `Thread.isMainThread == false` during key derivation in `prepareImport`; writes per D7 |
| R14 | Code review of `EncryptedBackupService` and `SerialManagerApp`; owner-run Release checklist (A14) prepared by QA |
| R15 | Review of `docs/design/gui.md` and of the string catalog (every new key has `en` and `it`) |
| R16 | CI green (`xcodebuild ... test`), no disabled test, grep for real-looking data |

## Open points for the Architect

- Shape of the repository import path: a new `LicenseRepository` method (for example an
  "upsert from backup" that takes a full record, or separate insert and replace with given
  id and dates) and how the in-memory fake implements it; keep the R7 lookup-before-insert.
- How the reader reuses `BackupFormat`, `BackupKeyDerivation` and `BackupPayload` (the
  decoder must widen to dates without fractions) and where the fixture file lives.
- How A4's above-64-MiB case is tested without slowing CI (sparse file, or the existing
  test-only `maxFileSize` parameter).
- Shape of the partial-failure error (D1) and its localized message.
- Ownership: data layer (Backend) versus `ImportModel` reload and strings (Frontend); the
  Frontend share may be small.
- `cancelImport()` (v2): which ticket owns the contract change and every `BackupService`
  conformer, and how the dependency between that change and the sheet's calls is ordered.
- Branch: `feature/encrypted-import` at `4efff0c` (`origin/main`, CI Release build and PR #14 merged) on
  2026-11-21.
