# Plan: User guide in the README (backlog #11)

- Plan version: v2 (v1 got CHANGES REQUESTED at PLAN review on 2026-11-21: B1 plus two non-blocking points)
- Date: 2026-11-21
- Input: `docs/specs/0011-user-guide.md` v1 (approved by Stefano on 2026-11-21, D1 to D4),
  `docs/adr/0001-storage.md`, `docs/adr/0003-keychain-implementation.md`,
  `docs/specs/0010-encrypted-import.md` v2 (worktree `feature-encrypted-import`, read only),
  baseline `4efff0c` (= `main` on 2026-11-21)
- Author: Architect
- Status: v2, waiting for PLAN re-review

Changelog v1 to v2:
- B1: Stefano's human gate before every commit, push, rebase and merge. T1 no longer commits: SPEC and
  plan stay in the working tree and are committed with the README after Stefano's authorization. T2
  edits `README.md` in the working tree without committing. T4 reviews the working diff. T5 merges
  `main` into `docs/user-guide` (rebase only if the branch was never pushed, never force-push), run by
  Git only after Stefano authorizes it. T6 proposes commit, push and PR to Stefano in one authorization.
- T3 also covers "The serial for this license is missing from the Keychain.", "Add Serial…" and
  "Backup Exported".
- Risks: the owner's optional Release run is the only end-to-end proof of A4's file round trip.

## 1. Findings that shape the plan

Checked on 2026-11-21 against `main` at `4efff0c` and the `feature-encrypted-import` worktree.

- **F1. #10 has no code yet.** `git log main..HEAD` in `feature-encrypted-import` is empty; the worktree
  holds only an uncommitted SPEC 0010 v2 and plan. The import section (R6) is therefore written from
  SPEC 0010 v2 and the pre-#10 `Sources/Views/ImportView.swift`. The partial-failure message of
  SPEC 0010 R10 does not exist in any source yet: the README describes the behaviour ("the licenses
  already imported stay, the message says how many") and does not quote the sentence until T5.
- **F2. #10 does not touch `README.md`.** Neither SPEC 0010 nor its plan mentions the README (grep).
  The two branches cannot conflict on that file; #10 edits `ImportView`, `Localizable.xcstrings` and
  `docs/design/gui.md`, which T5 re-reads.
- **F3. The Debug walkthrough of the SPEC Verification table cannot show the file round trip.**
  `Sources/Fakes/InMemoryBackupService.swift`: `export` only counts licenses and missing serials and
  writes no file; `prepareImport` never reads the chosen file, accepts only the password
  `test-password` (anything else gives `wrongPassword`) and always previews 5 licenses with 2
  conflicts; `applyImport` returns counts and adds nothing to the list. A Debug build therefore
  verifies the labels, the Skip/Replace choice, the summary and the wrong-password message. It cannot
  verify: a `.smbackup` file being written (A4, R5), the export/import round trip, the invalid-file and
  newer-version messages, or the R10 partial failure. Those rest on the source read (T3), #9/#10's
  automated tests and the owner's optional Release run. This changes a verification method, not
  approved behaviour (reported to PM, no SPEC change requested).
- **F4. Labels confirmed in source and catalog** (`Sources/AppCommands.swift`, `Sources/ContentView.swift`,
  `Sources/Views/*`, `Resources/Localizable.xcstrings`). File menu: New License (Cmd+N), Import
  Licenses… (Cmd+Shift+I), Export Licenses… (Cmd+Shift+E). License menu: Edit License (Cmd+E), Copy
  Serial (Cmd+Shift+C), Show or Hide Serial (Cmd+Shift+R), Delete License… (no shortcut). Toolbar "+"
  (help "New License"), empty-list button "Add License". Search prompt "Name or vendor". Form: Product
  Name (required, "Product name is required."), Vendor, Version, Serial, Registered Email, Notes, Save.
  Settings: Clear Clipboard, Never / After 30 Seconds / After 1 Minute (default, 60 s) / After 2 Minutes.
  Export sheet: Password, Confirm Password, "Use at least 12 characters.", Export…; default file name
  `SerialManager Backup <date>.smbackup`. Import errors: "The password is incorrect.", "This file isn't a
  valid SerialManager backup.", "This backup was made with a newer version of SerialManager." Every
  key checked has an Italian value. The app menu items (File, Settings…) are system-provided and are
  not in the catalog: their Italian names are the macOS ones (expected Archivio, Impostazioni…; T3
  confirms them by running the app with the Italian language, never from memory).
- **F5. Storage path.** `LicenseLibrary.folderName` is the bundle identifier, so the store is
  `~/Library/Application Support/<bundle id>/Licenses.store`. The README writes the path with `~` and
  never with a real home folder (R8).
- **F6. R7 wording boundary.** ADR 0003 quotes Apple: "Items with this attribute do not migrate to a
  new device." and `kSecAttrSynchronizable` false (no iCloud sync). The README stays inside these two
  statements; it does not name Migration Assistant, Time Machine or iCloud Keychain beyond "not synced"
  (SPEC R7).
- **F7. Install command.** The signed Release command is the one in
  `docs/qa/encrypted-export-release-checklist.md` (`-configuration Release -derivedDataPath build/release
  -allowProvisioningUpdates`); the app lands in `build/release/Build/Products/Release/SerialManager.app`.
  `Project.swift` pins `DEVELOPMENT_TEAM`; another reader sets their own team there. Debug runs on
  in-memory fakes (`Sources/SerialManagerApp.swift`).

## 2. Design of the README change

Section order after the change (R10):

1. Title, CI badge, one-line description (unchanged)
2. **Status** (D4): one or two lines naming what works at merge time (add, edit, delete, search, copy
   with clipboard clearing, encrypted export and import). Written for the post-#10 state, because the
   README is merged only after #10 (D1).
3. Requirements (unchanged)
4. **Install** (R1): build a signed Release app, where it lands, copy to `/Applications`, team
   signing and why (Keychain), Debug keeps nothing.
5. **Using SerialManager** with short subsections: Add a license (R2), Find a license (R3), Copy a
   serial (R4), Back up (R5), Restore (R6), Moving to another Mac (R7).
6. Build, tests, Xcode project note, License (unchanged byte for byte)

Writing rules: English prose; each UI label in English with the Italian label in brackets, e.g.
File > Export Licenses… (Archivio > Esporta licenze…) (D3); shortcuts as `Cmd+Shift+E`; examples only
with `Acme Editor`, vendor `Acme`, serial `ACME-0000-TEST-0000`, `user@example.com` (R8); paths with `~`;
about 60 to 120 new lines (R10). R7 includes one plain sentence a non-developer understands (A5), e.g.
"Copying the database to another Mac moves your licenses but not their serials: to move the serials,
use the encrypted export."

## 3. Tickets

| # | Ticket | Owner | Depends on | Parallel with | Requirements |
| --- | --- | --- | --- | --- | --- |
| T1 | Keep SPEC 0011 and this plan uncommitted in the working tree (no commit) | Git | PLAN approved | none | process |
| T2 | Write README sections and Status | frontend | T1 | T3 | R1 to R8, R10 |
| T3 | Label table from source (EN + IT) | qa (prep, read only) | T1 | T2 | R9 |
| T4 | Review and QA walkthrough | code-reviewer, qa | T2, T3 | none | R1 to R10 |
| T5 | Post-#10 recheck | Git (merge `main` in, after Stefano's authorization), frontend (fixes), code-reviewer + qa (recheck) | #10 merged on `main`, T4 | none | R6, R9, R11 |
| T6 | Commit, push and PR, then merge | Git, PM | T5 green; one authorization from Stefano for commit + push + PR, his gate again for the merge | none | R11 |

**Why one writer, and why frontend.** The change is about 100 lines in one file; two writers would
only add merge conflicts inside `README.md`. Nearly every line describes UI (menus, sheets, labels,
shortcuts, Italian strings), which is the frontend's area. The backend has no ticket: the storage
facts R7 needs are listed in F5 and F6, and T4 checks them against ADR 0003,
`KeychainSerialStore.swift` and `LicenseLibrary.swift`.

### T1. SPEC and plan stay in the working tree (Git)
- No commit (B1). `docs/specs/0011-user-guide.md` and `docs/plans/0011-user-guide-plan.md` stay
  untracked in the `docs-user-guide` worktree and are committed together with the README in T6, after
  Stefano's authorization.
- Verification: `git status --short` in the worktree lists the two files as untracked and nothing staged.

### T2. README user guide (frontend)
- Scope: `README.md` only. No code, strings, `Project.swift`, `PROJECT_BRIEF.md` or screenshots.
- Content: section 2 above, every fact taken from F4 to F7; R6 from SPEC 0010 v2 R1, R5 to R10 and
  R14 (import enabled also on an empty library) plus `ImportView`, without quoting the R10 message (F1).
- Outcome: `README.md` edited in the `docs-user-guide` working tree, NO commit (B1). The commit is
  proposed to Stefano in T6.
- Self-check before handing over: new-line count 60 to 120; `git diff main -- README.md` leaves
  Requirements, Build, tests and License unchanged; the R8 grep of section 4 returns only fake values.

### T3. Label table (qa, read only, in parallel with T2)
- Build, from `Sources/` and `Resources/Localizable.xcstrings` and without reading the draft, a table:
  English label, Italian value, shortcut, source file. Cover at least every label of F4, plus Add
  License, Save, Show Serial / Hide Serial, Existing Licenses, Skip, Replace, Done, the License menu
  title, the error sentences, "The serial for this license is missing from the Keychain.",
  "Add Serial…" and "Backup Exported".
- A label with no Italian value in the catalog is reported to PM, never invented. System items (File,
  Settings…) are marked "system, not in catalog".
- Outcome: the table posted as a team note (or a file in QA's area), reused in T4 and T5.

### T4. Review and QA walkthrough (after T2 and T3)
- Input: the working diff identified by Git: `git diff main -- README.md` plus the untracked
  `docs/specs/0011-user-guide.md` and `docs/plans/0011-user-guide-plan.md` (nothing is committed, B1).
- Reviewer (source read): R1 command against the checklist and `Project.swift`; Debug claim against
  `SerialManagerApp.swift`; R2 to R6 every claim against `Sources/`; R7 against ADR 0003,
  `KeychainSerialStore.swift`, `LicenseLibrary.swift` (F6 boundary); R10 line count, section order,
  untouched sections.
- QA (Debug build, fake data only), the recipe that works with the fakes (F3):
  - A2: Cmd+N, `Acme Editor` / `Acme` / `ACME-0000-TEST-0000`, Save; search `acme` shows it, `zzz` shows
    nothing; Save with empty Product Name shows "Product name is required.".
  - A3: select it, Cmd+Shift+C, paste shows the fake serial; with After 1 Minute the clipboard is
    empty after about a minute; Show/Hide toggles.
  - Export: Cmd+Shift+E, a fake password of 12+ characters twice, summary "Exported N licenses.". No
    file is written in Debug: only the labels and the 12-character rule are verified here.
  - Import: create an empty placeholder `Sample.smbackup` (e.g. in the scratchpad), Cmd+Shift+I,
    choose it; password `wrong-password` shows "The password is incorrect." and nothing changes;
    password `test-password` shows "Already in SerialManager: 2 of 5 licenses.", Skip gives
    Imported 3 / Replaced 0 / Skipped 2, Replace gives 3 / 2 / 0.
  - Not observable in Debug (left to T5 source recheck, #10's tests and the owner's Release run):
    file written, round trip, invalid-file and newer-version messages, partial failure.
  - R8: read the working diff `git diff main -- README.md` and the two untracked docs in full; grep them for `@`, `/Users/`, and key-shaped
    strings (e.g. `[A-Z0-9]{4,}-[A-Z0-9]{4,}`); only the fake values may match.
  - R9: compare the README line by line with the T3 table.
- Outcome: verdicts posted to PM; fixes go back to frontend (T2) and loop.

### T5. Post-#10 recheck (after #10 is on `main`)
- Git: confirm `gh pr view <#10 PR> --json state,mergedAt`, then merge `main` into `docs/user-guide`
  (rebase only if the branch was never pushed; never force-push). Git runs it only after Stefano
  authorizes it (B1). With nothing committed on the branch yet, the uncommitted README, SPEC and plan
  ride along; Git states how it handles them when it asks for the authorization.
- Re-diff against the merged code: `ImportView.swift` strings, the SPEC 0010 R10 partial-failure
  message and its Italian value, `EncryptedBackupService.isImportAvailable`, `docs/design/gui.md`
  Import section, new keys in `Localizable.xcstrings`.
- Frontend: adjust R6 and Status if any wording differs; QA updates the T3 table; Reviewer and QA
  recheck R6 and R9 on that revision.
- Optional, owner only: A1 and A4 on a signed Release build with fake entries (`Acme …`) only.

### T6. Commit, push, PR and merge (Git, PM)
- After T5, Git proposes to Stefano in one authorization: the commit of `README.md`, the SPEC and this
  plan on `docs/user-guide` (Conventional Commits), the push and the PR into `main`.
- The merge follows CI green and Stefano's gate (R11).

## 4. Parallelism

T2 and T3 run in parallel after T1 (no commit, so they can start as soon as the plan is approved). T4 needs both. T5 waits on an external event (#10 merged), so the
work of T2 to T4 can finish now and the branch then stays open until #10 lands.

## 5. Requirement coverage

| Req | Ticket | Method |
| --- | --- | --- |
| R1 | T2, T4 | Command vs checklist and `Project.swift`; Debug claim vs `SerialManagerApp.swift` |
| R2 | T2, T4 | Source read; QA A2 in Debug |
| R3 | T2, T4 | Source read; QA A2 search `acme` / `zzz` |
| R4 | T2, T4 | Source read (`Clipboard.swift`, `SettingsView.swift`, `SerialRow.swift`); QA A3 |
| R5 | T2, T4 | Source read (`ExportView.swift`, `BackupFileType.swift`); QA export labels in Debug (no file, F3) |
| R6 | T2, T4, T5 | SPEC 0010 v2 + `ImportView`; QA import recipe in Debug; recheck on merged #10 |
| R7 | T2, T4 | ADR 0003, `KeychainSerialStore.swift`, `LicenseLibrary.swift`; A5 sentence present |
| R8 | T2, T4 | Full diff read plus grep for `@`, `/Users/`, key-shaped strings |
| R9 | T3, T4, T5 | Independent label table vs README, redone after #10 |
| R10 | T2, T4 | Line count 60 to 120, section order, Build/tests/License unchanged in the diff |
| R11 | T5, T6 | `gh pr view` of #10 `mergedAt`, `main` merged in after Stefano's authorization, R6/R9 rechecked before merge |

## 6. Risks

- #10 may change import strings or flow after this guide is written: T5 exists for that; the branch
  must not merge earlier.
- The owner's optional Release run (A1 and A4 with fake `Acme …` entries) is the only end-to-end proof
  of A4's file round trip: Debug writes no file and its import ignores the file (F3), and the
  automated tests of #9 and #10 cover the service, not the app as shipped. If the owner skips it, that
  proof is missing at merge.
- A reader may run the Debug build and believe data is saved: R1 says it in Install, in plain words.
- The README names the owner's `DEVELOPMENT_TEAM` only by pointing to `Project.swift`; no team ID,
  name or email is copied into the README.
