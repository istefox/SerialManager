# SPEC: User guide in the README (backlog #11)

- Version: v1
- Date: 2026-11-21
- Status: v1 approved by the owner on 2026-11-21 (D1 to D4 included)
- Related: `README.md`, `docs/adr/0001-storage.md`, `docs/adr/0002-backup-format.md`,
  `docs/adr/0003-keychain-implementation.md`, `docs/specs/0009-encrypted-export.md`,
  `docs/specs/0010-encrypted-import.md` (branch `feature/encrypted-import`, SPEC v2 approved),
  `docs/qa/encrypted-export-release-checklist.md`

## Goal

A short user guide in the README tells the owner (and any reader of the public repository) how
to get a usable app, add a license, find it, copy its serial, back the library up and restore
it on another Mac. It states plainly that copying the database alone does not bring the serials
along: moving to another Mac needs the encrypted export.

## Current state (evidence, 2026-11-21, `main` at `4efff0c`)

- `README.md` has Status ("Bootstrap, under active development", stale), Requirements, Build
  (Debug build and CI-style tests), License. No user guide.
- The `xcodebuild ... build` command in the README produces a Debug build. Debug runs on
  in-memory fakes with fake sample data (`Sources/SerialManagerApp.swift`): nothing typed is kept.
- Release uses SwiftData at `~/Library/Application Support/<folder>/Licenses.store`
  (`Sources/Data/LicenseLibrary.swift`) and serials in the data protection keychain, items
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never synchronizable
  (`Sources/Data/Serials/KeychainSerialStore.swift`, ADR 0003). Keychain access needs the app
  signed with an Apple Development identity; `Project.swift` pins `DEVELOPMENT_TEAM` to
  `T7H24G7BFW`. The signed Release build command is in
  `docs/qa/encrypted-export-release-checklist.md`.
- Working today: New License (Cmd+N, toolbar "+", "Add License" on the empty list), Edit (Cmd+E),
  Delete; sidebar search "Name or vendor" (matches product name or vendor); serial row with
  Show/Hide and Copy, License > Copy Serial (Cmd+Shift+C), Show or Hide Serial (Cmd+Shift+R);
  Settings > Clear Clipboard (Never, 30 s, 1 min default, 2 min), which clears only the serial
  it copied; File > Export Licenses… (Cmd+Shift+E), password of at least 12 characters,
  unrecoverable if forgotten, disabled on an empty library; file extension `.smbackup`.
- Not yet in Release: File > Import Licenses… (Cmd+Shift+I) is disabled
  (`EncryptedBackupService.isImportAvailable == false`) until #10. The import UI exists
  (`Sources/Views/ImportView.swift`): password, wrong password / invalid file / newer version
  errors, Skip or Replace for licenses already present, summary Imported / Replaced / Skipped.
  SPEC 0010 v2 R10: a write error stops the import, licenses before it keep their changes and
  the message gives the counts.
- The app is localized in English and Italian (`Resources/Localizable.xcstrings`).

## Decisions

- D1 (owner, 2026-11-21): write the whole guide now, import included, following SPEC 0010 v2
  and the existing import UI. The README is merged only after #10 is on `main`, and the import
  section is verified against the merged #10 code before that merge.
- D2 (owner, 2026-11-21): the guide includes a short Install section for a usable (signed
  Release) app.
- D3 (proposed in this SPEC): the README stays in English like the rest of the repository; each
  UI label is given in English with the Italian label in brackets, as in the QA checklists.
- D4 (proposed in this SPEC): the stale Status line is updated in the same change, because the
  guide would contradict "Bootstrap".

## Scope

In scope: `README.md` only (new sections Install and Using SerialManager, updated Status line).
Out of scope: screenshots, a separate user manual or help book, in-app help, changes to code,
strings or `Project.swift`, a downloadable signed build or notarization, `PROJECT_BRIEF.md`
(its Status is updated by the milestone owner, not by this ticket), translations of the README.

## Requirements

- R1. Install: the README explains how to build a signed Release app (`tuist generate --no-open`,
  then `xcodebuild ... -configuration Release ... -allowProvisioningUpdates build`, the same
  command as the export checklist), where the `.app` lands, and that it can be copied to
  `/Applications`. It says that signing needs an Apple Development team (a reader with another
  team sets their own `DEVELOPMENT_TEAM` in `Project.swift`) because serials live in the
  Keychain, and that a Debug build or a run from Xcode in Debug uses fake sample data and keeps
  nothing.
- R2. Add: how to create a license (File > New License, Cmd+N, or the "+" toolbar button), that
  Product Name is required, what Save does; one line each on Edit (Cmd+E) and Delete.
- R3. Search: the sidebar search field matches product name or vendor.
- R4. Copy: select a license, the serial is hidden by default, Show/Hide, Copy (button or
  License > Copy Serial, Cmd+Shift+C); the clipboard is cleared after the delay set in
  Settings (default 1 minute, or Never), and only if it still holds that serial. What the
  "serial missing from the Keychain" message means and the Add Serial… button.
- R5. Export: File > Export Licenses… (Cmd+Shift+E), password of at least 12 characters typed
  twice, a forgotten password cannot be recovered, the `.smbackup` file holds every license and
  serial encrypted, Export is disabled while the library is empty. Advice: keep the file and the
  password apart, never in the repository.
- R6. Import: File > Import Licenses… (Cmd+Shift+I), choose the `.smbackup` file, type its
  password; a wrong password, an invalid file or a newer backup version changes nothing; when
  some licenses already exist the user picks Skip (keep yours) or Replace (overwrite with the
  backup); the summary counts Imported, Replaced, Skipped; if an error stops the import part way,
  the licenses already imported stay and the message says how many. Wording matches the merged
  #10 behavior (D1).
- R7. Moving to another Mac: a dedicated section says that serials are stored in this Mac's
  Keychain as items that do not migrate to another device and are not synced, so copying
  `Licenses.store` (or the Application Support folder) brings only the license entries: the
  serials stay behind and the new Mac shows the "missing from the Keychain" message. The
  supported path is: Export on the old Mac, move the `.smbackup` file, install the app on the
  new Mac, Import. Claims about migration rest on ADR 0003's quoted Apple documentation; no
  claim about Migration Assistant, Time Machine or iCloud Keychain beyond it.
- R8. Fake data only: every example uses obviously fake values (for example `Acme Editor`,
  vendor `Acme`, serial `ACME-0000-TEST-0000`, `user@example.com`). No real serial, key, name,
  email or path containing a real username.
- R9. Accuracy: every menu item, button, shortcut, label (English and Italian) and default in
  the guide matches the source at the reviewed revision.
- R10. Short and placed for users: the guide sits after Requirements and before the developer
  Build section, about 60 to 120 lines of Markdown; the existing Build, tests and License content
  is kept unchanged. Status is updated (D4) to say what works.
- R11. Merge gate (D1): the change is not merged before #10 is on `main`; once #10 is merged,
  the branch is updated and R6 and R9 are rechecked on that revision.

## Acceptance examples

- A1 (R1). A reader following Install ends with `SerialManager.app` from
  `build/release/Build/Products/Release/`; the guide warns that the Debug build keeps nothing.
- A2 (R2, R3). Following the guide: Cmd+N, Product Name `Acme Editor`, Vendor `Acme`, Serial
  `ACME-0000-TEST-0000`, Save; typing `acme` in the search field shows it; typing `zzz` shows
  nothing.
- A3 (R4). Select `Acme Editor`, press Cmd+Shift+C: the serial is on the clipboard and, with the
  default setting, gone after about a minute.
- A4 (R5, R6, R7). Export with a 12+ character password produces one `.smbackup`; Import of that
  file with the same password on a library that already holds `Acme Editor` asks Skip or Replace
  and ends with a summary; a wrong password shows "The password is incorrect." and changes
  nothing.
- A5 (R7). The README states, in one sentence a non-developer understands, that copying the
  database to another Mac does not carry the serials and that the encrypted export is the way
  to move them.
- A6 (R8). A search of the diff for anything resembling a real key, email or username finds only
  the fake values above.

## Verification

| Req | Method | Who |
| --- | --- | --- |
| R1 | Command compared with `docs/qa/encrypted-export-release-checklist.md` and `Project.swift`; Debug claim checked in `Sources/SerialManagerApp.swift` | Reviewer |
| R2 to R6 | Each label and shortcut cross-checked against `Sources/` and `Localizable.xcstrings`; walkthrough of A2 to A4 on a Debug build (fakes: export and import, Skip/Replace included, work in Debug) | Reviewer (source), QA (walkthrough) |
| R6 | Recheck against the merged #10 code (`EncryptedBackupService`, `ImportView`, SPEC 0010 v2 R10) | Reviewer, QA |
| R7 | Statements checked against ADR 0003, `KeychainSerialStore.swift`, `LicenseLibrary.swift` | Reviewer, QA |
| R8 | `git diff` read in full plus a grep for `@`, `/Users/`, key-shaped strings | Reviewer, QA |
| R9 | Label table built by QA from source, compared line by line with the README | QA |
| R10 | Line count and section order; diff shows Build/License untouched | Reviewer |
| R11 | `gh pr view` of #10 merged and branch rebased before merge | Git, PM |
| Owner (optional) | A1 and A4 on a signed Release build with fake entries only | Stefano |

## Open questions

None.
