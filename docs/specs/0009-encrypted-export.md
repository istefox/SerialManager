# SPEC: Encrypted export of licenses and serials (backlog #9)

- Version: v1 (approved 2026-11-20)
- Date: 2026-11-20
- Status: approved by the owner on 2026-11-20 (D1 to D5 included)
- Related: `docs/adr/0002-backup-format.md` (format, crypto, payload: normative),
  `docs/adr/0001-storage.md`, `docs/design/gui.md` ("Export"),
  `Sources/Contract/LicenseContract.swift`, backlog #10 (import, blocked by this ticket)

## Goal

The owner saves a single password-protected backup file that holds every license and its
serial, so that losing the Mac or the library does not lose the licenses. The file is the
version 1 format of ADR 0002 and reveals nothing without the password.

## Current state (evidence, 2026-11-20, worktree `feature-encrypted-export` at `9fa7a4b`)

Already in place (GUI and contract, on main):

- File > Export Licenses... (`Cmd+Shift+E`) in `Sources/AppCommands.swift`, disabled when the
  service is unavailable or there are no licenses.
- `Sources/Views/ExportView.swift`: Password and Confirm Password, inline mismatch message,
  `NSSavePanel` with default name `SerialManager Backup YYYY-MM-DD.smbackup`
  (`Sources/Support/BackupFileType.swift`), progress while exporting, summary
  ("Exported N licenses.", "Without a serial in the Keychain: M"), Show in Finder, and a
  Failed state with Try Again. The explanation already says a forgotten password cannot be
  recovered, in English and Italian.
- `ExportModel` (`Sources/Store/BackupModels.swift`): `canExport` requires a non-empty
  password equal to the confirmation; errors are shown through `Phase.failed(String)`.
- Contract: `BackupService.export(to:password:) -> ExportSummary(licenseCount:missingSerialCount:)`.
  `LicenseRepository.serial(for:)` returns nil for a missing Keychain item and throws
  `SerialStoreError` (`accessDenied`, `undecodableData`, `unexpected`) on a real failure.
- Debug builds use `InMemoryBackupService` (writes nothing); Release builds use
  `UnavailableBackupService`, so Import and Export are disabled in the File menu.
- `AppCommands` drives Import and Export with one flag, `backupAvailable`
  (`BackupService.isAvailable`, a type check against `UnavailableBackupService`).
- Tests: `Tests/BackupModelTests.swift` covers `ExportModel` on the fake with the 6-character
  password `sample`.

Missing: a real `BackupService` export (key derivation, encryption, file layout, payload),
the 12-character minimum, an export error type, the Release wiring, tests on the real file.

## Decisions

From ADR 0002 and the ticket updates of 2026-11-19 (not reopened here): PBKDF2-HMAC-SHA256 via
CommonCrypto at 600,000 iterations with a new 16-byte salt; AES-256-GCM via CryptoKit with a new
nonce; binary header v1 passed as associated data; NFC password normalization; 64 MiB cap on the
whole file, checked before writing; atomic write; payload JSON with ISO 8601 UTC dates at three
fractional digits and `serial` null (never `""`) when missing or empty; password of at least 12
Swift `Character`s, no trimming; injectable salt, nonce and clock sources; derivation off the
main actor; no third-party dependency.

Taken with the owner on 2026-11-20:

- D1: in Release, after this ticket, File > Import Licenses... stays disabled until #10 lands;
  Export is enabled. Import and Export get separate availability. (Answer given by the owner's
  personal assistant under the owner's standing rule "pick the recommended option"; the owner
  confirms or changes it by approving this SPEC.)
- D2: if reading a serial from the Keychain fails (any `SerialStoreError`, or any other error
  thrown by `serial(for:)`), the export stops: no file is created and an existing destination
  file is left unchanged, and the sheet shows Export Failed with the error message and
  Try Again. Only a missing item (nil) or an empty value becomes `serial: null`.

Proposed by the PM, accepted or changed by approving this SPEC:

- D3: the sheet shows a permanent hint under the password fields: "Use at least 12
  characters." (Italian: "Usa almeno 12 caratteri."), so a disabled Export button is never
  unexplained.
- D4: Debug builds and previews stay on the in-memory fakes. The real export is verified by
  automated tests in CI plus an optional manual checklist on a Release build that QA prepares
  and only the owner runs (same pattern as backlog #6).
- D5: the summary keeps reporting the number of licenses without a serial, not their names
  (fixed contract `ExportSummary`).

## In scope

- A real `BackupService` whose `export(to:password:)` implements ADR 0002 sections 1, 2, 3, 6
  and 8 (export side).
- An export error type with user-facing messages in English and Italian.
- `ExportModel` and `ExportView` changes for the 12-character minimum and the hint.
- Release wiring in `SerialManagerApp.init()` and separate Import/Export availability in the
  File menu.
- A decryption path reachable from tests, to prove the round trip.
- Tests, `docs/design/gui.md` and `Resources/Localizable.xcstrings` updates.

## Out of scope

- Import (backlog #10): `prepareImport`, `applyImport`, the import bounds and error mapping of
  ADR 0002 sections 4 and 5, enabling the Import menu. In the real service both import methods
  keep failing with the existing "Backup isn't available yet" error until #10.
- Opening a backup by double-clicking it in Finder, automatic or scheduled backups, CSV export,
  scrypt or Argon2id, listing which licenses lack a serial.
- Any change to the file format or to the crypto parameters fixed by ADR 0002.

## Requirements

- R1. File format: the real `export(to:password:)` writes exactly one file in the version 1
  layout of ADR 0002 section 3: magic `SMBACKUP`, version `1`, KDF id `0x01`, iterations
  600,000, salt length 16, 16 salt bytes, cipher id `0x01`, 12 nonce bytes, ciphertext length
  `L`, ciphertext, 16-byte tag. File size is `33+S+L+16`. The header bytes `[0, 33+S)` are the
  AES-GCM associated data.
- R2. Crypto: the key is PBKDF2-HMAC-SHA256 (`CCKeyDerivationPBKDF`) of the NFC-normalized,
  UTF-8 encoded password with the header salt and iteration count, 32 bytes; the payload is
  sealed with AES-256-GCM (CryptoKit). No third-party dependency is added.
- R3. Payload: the plaintext is the UTF-8 JSON object of ADR 0002 section 6: `exportedAt` from
  the clock source, and one element per license from `fetchAll()` carrying every
  `LicenseSummary` field plus `serial`. Dates are `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC;
  `purchaseDate` is null when unset; `serial` is null when `serial(for:)` returns nil or an
  empty string, and is never `""`. An empty library produces `"licenses": []`.
- R4. Summary: the returned `ExportSummary.licenseCount` is the number of exported licenses and
  `missingSerialCount` the number of null serials in the payload.
- R5. Nothing in clear: the file contains no serial, no license field and no `exportedAt` in
  clear text; only the header fields of R1 are readable without the password.
- R6. Password rule: `ExportModel.canExport` is true only when the password has at least 12
  Swift `Character`s (no trimming), the confirmation is equal, and the phase is `entering`. The
  sheet shows the hint of D3. The mismatch message is unchanged.
- R7. Size cap: the service computes the final size before writing; above 67,108,864 bytes the
  export fails with a dedicated error ("The backup is larger than 64 MB, the maximum size."
  / Italian equivalent) and neither creates nor changes the destination file.
- R8. Keychain read failure (D2): the export fails with the error thrown by `serial(for:)`,
  shown through `Phase.failed` with its existing user-facing message; no file is created or
  changed.
- R9. Atomic write: the destination is replaced only by a complete file. On any failure (R7,
  R8, a write error) a destination that existed before keeps its exact bytes, and one that did
  not exist is not created.
- R10. Fresh randomness: salt (`SecRandomCopyBytes`), nonce (`AES.GCM.Nonce()`) and clock
  (`Date()`) are injectable sources with these defaults. Two exports of the same data with the
  same password produce different files.
- R11. Off the main actor: key derivation, encryption and the file write do not run on the
  main actor; the sheet stays in its Exporting state with the progress indicator meanwhile.
- R12. Secrets hygiene: the password, the derived key and the plaintext payload are never
  persisted, logged or included in an error message.
- R13. Release wiring (D1): `SerialManagerApp.init()` uses the real service in Release. The
  File menu enables Export (when there is at least one license) and keeps Import disabled
  until #10. Debug builds and previews stay on the fakes (D4).
- R14. Docs and strings: `docs/design/gui.md` (Export section, states, known gaps) describes
  the 12-character rule, the hint, the new failure messages and the Import availability; every
  new user-facing string has English and Italian in `Resources/Localizable.xcstrings`.
- R15. Tests (Swift Testing, CI): automated tests cover R1 to R10 with fake data and fake
  passwords only, using the in-memory license repository and serial store, never the real
  Keychain. Existing `ExportModelTests` move to fake passwords of 12 or more characters; no
  test is disabled.

## Acceptance examples

All values are fake.

- A1 (R1, R3, R4). Two licenses: "Sample Editor" with serial `FAKE-0000-0000-0000`, and
  "Sample Viewer" with no Keychain item. Password `sample-backup-pass`. The file starts with
  `53 4D 42 41 43 4B 55 50`, `00 01`, `01`, `00 09 27 C0`, `10`; the summary is
  `licenseCount 2, missingSerialCount 1`; decrypting gives both licenses with all their fields
  (dates equal at millisecond precision), the second with `serial: null`.
- A2 (R6). Password `short-pass` (10 characters) twice: Export disabled. `sample-backup-pass`
  twice: enabled. `sample-backup-pass` and `sample-backup-paSS`: mismatch shown, disabled.
  Twelve spaces twice: enabled (no trimming).
- A3 (R2). Password `cafe\u{301}-sample-pw` (decomposed accent) at export; decrypting with
  `caf\u{E9}-sample-pw` (precomposed) succeeds.
- A4 (R3, R4). A license whose serial item holds `""`: exported with `serial: null`, counted
  in `missingSerialCount`.
- A5 (R8, R9). The serial store throws `accessDenied` for one license: the export fails,
  the sheet shows the access-denied message and Try Again, the destination does not exist
  afterwards; with a pre-existing destination file, its bytes are unchanged.
- A6 (R7, R9). A library whose payload makes the file exceed 64 MiB: the export fails with the
  size message, no file is created and a pre-existing file is unchanged.
- A7 (R10). Two exports of A1's data with the same password: the files differ (salt and
  nonce). With fixed salt, nonce and clock sources: header fields equal the injected values.
- A8 (R5). The bytes of A1's file contain neither `FAKE-0000-0000-0000` nor `Sample Editor`
  nor `user@example.com` as UTF-8.
- A9 (R13). Release build with at least one license: File > Export Licenses... enabled,
  File > Import Licenses... disabled.
- A10 (R3). Empty library through the service: `"licenses": []`, summary `0, 0` (the menu
  item itself stays disabled with no licenses).

## Verification

| Req | Method |
| --- | --- |
| R1, R2, R3, R4, R5, R10 | Unit tests on the real service (A1, A3, A4, A7, A8, A10), round trip through the test-visible decryption path |
| R6 | `ExportModelTests` (A2) plus code review of the hint in `ExportView` |
| R7, R8, R9 | Unit tests with a temporary directory (A5, A6), checking existence and bytes of the destination |
| R11, R12 | Code review; R11 also by a test that the service API is `async` and not main-actor isolated |
| R13 | Code review of `SerialManagerApp.init()` and `AppCommands`; optional owner-run Release checklist (A9) prepared by QA |
| R14 | Review of `docs/design/gui.md` and of the string catalog (every new key has `en` and `it`) |
| R15 | CI green (`xcodebuild ... test`), no disabled test, grep for real-looking data |

## Open points for the Architect

- Shape of the export error type and how the existing `SerialStoreError` messages are reused
  for R8.
- How A6 is tested without making CI slow (large fake fixture, or an internal cap parameter
  with the 64 MiB constant as the only production value; ADR 0002 keeps one constant).
- Where the test-visible decryption lives, and whether #10 builds its reader on it.
- How availability is split for D1 (contract change on `BackupService`/`isAvailable` and
  `AppCommands`).
- Conflict-prone shared files, live in other worktrees (#5, #7, #13): `Resources/Localizable.xcstrings`,
  `Sources/SerialManagerApp.swift`, `Sources/AppCommands.swift`, `docs/design/gui.md`.
- Branch: the worktree is at `9fa7a4b`, equal to `main` on 2026-11-20; rebase on `origin/main`
  before implementation if main moved.
