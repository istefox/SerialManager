# SPEC 0007: License detail with masked serial, verified on the real Keychain

Backlog ticket #7 "Dettaglio con seriale nascosto e copia negli appunti". Status: draft v1.1,
2026-11-20, awaiting approval.

## Context

The detail view with a masked serial, Show/Hide, Copy and the "serial missing" state is already
on main (`Sources/Views/LicenseDetailView.swift`, `Sources/Views/SerialRow.swift`). Until ticket
#4 it ran only on in-memory fakes. Ticket #4 (PR #6, merged as `3352eb6`) wired Release builds to
the real repository: entries in SwiftData, serials in the Keychain (`LicenseLibrary`). Debug
builds and previews stay on the fakes, so the real Keychain is reachable only from a signed
Release build.

This ticket verifies the four acceptance criteria and the License menu commands on that build,
and fixes two defects found by reading the code (R6, R7).

## Decisions

- D1 (Stefano, 2026-11-20): the ticket waited for #4 to be on main. #4 is merged.
- D2 (Stefano, 2026-11-20): the two defects (R6, R7) are fixed inside this ticket, with tests,
  code review and QA, not in new tickets. Stefano answered for the case "if QA confirms them";
  both are already confirmed by reading `origin/main` at `3352eb6`: `AppCommands` disables Copy
  Serial and Show or Hide Serial only when nothing is selected, and `LicenseDetailView` is not
  keyed per entry, while its `.task` resets `isRevealed` and the lookup but not `showsCopied`.
- D3: the detail views are not rewritten. Fixes are the smallest change that meets R6 and R7.
- D4: verification uses a Release build signed with team T7H24G7BFW, as for #4. That build
  writes to the user's real library (`Application Support/it.stefer.SerialManager/Licenses.store`)
  and real Keychain, so R9 applies.
- D6 (Stefano, 2026-11-20): the QA agent runs A1 to A10 itself, driving the app (this needs
  the Accessibility permission). The checks it cannot run, it hands to Stefano as a short
  checklist; Stefano runs them and reports the results, and QA gives the verdict on both.
- D5: the manual checks run with the app in English. The quoted texts are the English strings;
  the Italian ones in `Resources/Localizable.xcstrings` are listed under "Localized texts" for a
  Mac set to Italian.

## Scope

In scope:
- Manual verification of R1 to R5 on a signed Release build, against the real Keychain.
- Fix of R6 and R7, with tests, review and QA (D2).
- Updating `docs/design/gui.md` if the fix for R7 changes the documented menu behavior.

Out of scope:
- Rewriting `LicenseDetailView` or `SerialRow` (D3).
- Keychain error messages (access denied, unexpected status) and the library-unavailable
  state: verified under #4.
- Auto-hiding a revealed serial after a delay, export and import (#9, #10), Try Again recovery.
- Debug builds and previews, which keep the fakes.

## Requirements

- R1. Masked by default. Selecting an entry whose serial is in the Keychain shows the serial
  row as 12 fixed dots, whatever the real length, with Show and Copy available. The serial
  is masked again after selecting another entry and coming back, and after quitting and
  relaunching the app.
- R2. Show and Hide. Show reveals the exact value stored in the Keychain, monospaced and
  selectable. Hide masks it again. License > Show or Hide Serial (`Cmd+Shift+R`) does the same
  as the button, and pressing it twice in a row toggles twice.
- R3. Copy. The Copy button and License > Copy Serial (`Cmd+Shift+C`) put the exact serial on
  the general pasteboard, also while it is masked, without revealing it. The pasteboard also
  carries the `org.nspasteboard.ConcealedType` marker. The button shows "Copied" with a
  checkmark for about 1.5 seconds and VoiceOver announces "Serial copied". After the delay
  set in Settings (default 60 seconds) the pasteboard is cleared, unless something else was
  copied in the meantime, in which case it is left alone.
- R4. Missing serial. An entry with no Keychain item shows "The serial for this license is
  missing from the Keychain." and an "Add Serial…" button. The button opens the edit form
  with focus on the serial field. After saving a serial there, the detail shows the masked
  serial (R1).
- R5. Accessibility. The Show and Hide buttons are exposed as "Show Serial" and "Hide Serial",
  the Copy button as "Copy Serial", and the masked text as "Hidden".
- R6. No state carried across entries. After selecting another entry, the
  new entry never shows, even briefly, the previous entry's serial, its revealed state, or a
  "Copied" confirmation from a copy made on the previous entry. Its row starts as loading or
  masked, with the Copy button reading "Copy".
- R7. Menu commands follow the serial state. License > Copy Serial and
  License > Show or Hide Serial are disabled when the selected entry has no serial available
  (missing, still loading, or failed to load), not only when nothing is selected. Edit License
  and Delete License keep their current behavior.
- R8. No regression. `xcodebuild test` passes and CI (`Build and test`) is green on the final
  revision. The fixes for R6 and R7 come with automated tests where the logic is testable
  outside the GUI (for example, the state that decides whether the menu commands are enabled).
- R9. Test data hygiene. Manual checks use only obviously fake values (such as
  `FAKE-0007-TEST-0001`) and entry names prefixed `QA 0007`. Every entry created for the checks
  is deleted at the end, and its Keychain item with it. No real serial appears in the
  repository, tests, screenshots or reports.

## Acceptance examples

- A1 (R1). Create "QA 0007 Alpha" with serial `FAKE-0007-TEST-0001`. Select it: the row shows
  `••••••••••••`. Create "QA 0007 Long" with a 48-character fake serial: still 12 dots.
- A2 (R1). Reveal Alpha, select Long, select Alpha again: Alpha is masked. Reveal Alpha, quit,
  relaunch, select Alpha: masked.
- A3 (R2). Masked Alpha, press `Cmd+Shift+R`: `FAKE-0007-TEST-0001` is shown. Press it again:
  masked.
- A4 (R3). Check that Settings has the default clear delay of 60 seconds. Masked Alpha, press `Cmd+Shift+C`, then paste in TextEdit: `FAKE-0007-TEST-0001`.
  The row stayed masked and the button showed "Copied". Wait 60 seconds: the pasteboard is
  empty.
- A5 (R3). Copy Alpha's serial, then copy any other text within 60 seconds. After 60 seconds
  that other text is still on the pasteboard.
- A6 (R4). Create "QA 0007 Empty" with an empty serial. Its detail shows the missing-serial
  warning and "Add Serial…". Click it, type `FAKE-0007-TEST-0002`, save: the detail shows the
  masked serial and Copy works.
- A7 (R5). With Accessibility Inspector or VoiceOver, the buttons read "Show Serial", then
  "Hide Serial" once revealed, and "Copy Serial", and the masked text reads "Hidden".
- A8 (R6). Reveal Alpha and click Copy, then select Long within 1.5 seconds: Long never shows
  Alpha's serial, never appears revealed, and its Copy button reads "Copy".
- A9 (R7). Select "QA 0007 Empty" before A6 adds its serial: in the License menu, Copy Serial
  and Show or Hide Serial are disabled, while Edit License and Delete License are enabled.
  Select Alpha: they are enabled.
- A10 (R9). At the end, the list contains no "QA 0007" entries.

## Verification

| Requirement | How |
| --- | --- |
| R1 to R5 | QA, manual, on a Release build signed with team T7H24G7BFW, examples A1 to A7. Pasteboard content checked by pasting or with `pbpaste`, the concealed marker by listing the pasteboard types (a short Swift or AppleScript check), accessibility with Accessibility Inspector or VoiceOver |
| R6 | The "Copied" half: QA, manual, A8 on the fixed build, plus a test where the logic allows it. The stale-serial half lasts at most a frame and cannot be judged by eye: the Reviewer checks in code that the detail state is reset or re-created per entry before the new entry renders |
| R7 | A unit test on the logic that enables the two menu commands, code review, and QA, manual, A9 on the fixed build |
| R8 | `xcodebuild ... test` run by the developer and by QA on the final revision; CI green on the PR |
| R9 | QA states the values used and confirms A10; the Reviewer checks the diff for real-looking serials |

QA reports, per requirement, PASS, FAIL (expected versus observed) or BLOCKED (missing
prerequisite), with the revision tested.

## Localized texts

From `Resources/Localizable.xcstrings` on `3352eb6`, English then Italian:

| English | Italian |
| --- | --- |
| Show Serial | Mostra seriale |
| Hide Serial | Nascondi seriale |
| Copy Serial | Copia seriale |
| Copy | Copia |
| Copied | Copiato |
| Hidden | Nascosto |
| Serial copied | Seriale copiato |
| The serial for this license is missing from the Keychain. | Il seriale di questa licenza non è nel Portachiavi. |
| Add Serial… | Aggiungi seriale… |
| Show or Hide Serial | Mostra o nascondi seriale |

## Preconditions

- Branch `feature/license-detail` updated to `origin/main` at `3352eb6` (it has no commits of its own, so
  this is a fast-forward), with Stefano's approval for that Git write.
- A Mac where the signed Release build runs (the one used for #4 QA).

## Open points for the Architect

- R6: the smallest reliable reset of the detail state per entry (for example, identity of the
  detail view per entry id, or resetting `showsCopied` and the lookup when the entry changes)
  and how to prove it without a UI test target.
- R7: how the License menu learns whether the selected entry has a serial available. Today
  the lookup lives in the view's `@State`, while `AppCommands` reads only `LicenseStore`.
  Ownership: this is GUI work (Frontend). Backend has no expected work, to be confirmed.
