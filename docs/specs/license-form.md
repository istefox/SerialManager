# SPEC: Create, edit and delete a license on persistent data (backlog #6)

- Version: v1
- Date: 2026-11-20
- Status: approved by the owner on 2026-11-20
- Related: `docs/design/gui.md` ("License form", "Contract with the data layer"),
  `Sources/Contract/LicenseContract.swift`, backlog #4 (real `LicenseRepository`),
  `docs/specs/license-model.md` (#2), `docs/specs/0003-serial-store.md` (#3)

## Goal

The owner adds, corrects and deletes licenses from the form, and what they see is what is
stored: the license record in SwiftData and its serial in the serial store stay in step
through every create, edit, delete and cancel.

## Current state (evidence, 2026-11-20, worktree `feature-license-form` at `b8d6e14`)

The form flow is already on main (commit 61dd579) and runs on in-memory fakes:

- Cmd+N: `AppCommands` sends `router.send(.newLicense)` (disabled until the store is
  loaded); `ContentView` presents `LicenseFormView` with a new `LicenseFormModel`.
- Required name: `LicenseFormModel.save` refuses a blank or whitespace-only product name,
  sets `showsNameError`, and the view shows "Product name is required." and focuses the
  field.
- Edit: `LicenseStore.save(_:id:)` calls `repository.update(id:with:)` with a normalized
  draft. The form loads the serial and refuses to save an empty serial when the current one
  could not be read (`serialUnreadable`), so a Keychain error never becomes a silent delete.
- Delete: confirmation "Delete 'Product'? This also removes its serial from the Keychain.
  This can't be undone." in the form and in the main window (`DeleteConfirmation`).
- Cancel: dismisses without saving; asks "Discard changes?" first when the draft changed.
- Tests: `Tests/LicenseFormModelTests.swift` and `Tests/LicenseStoreTests.swift` cover
  these paths on `InMemoryLicenseRepository` (read, not run, while writing this SPEC).

What is missing: no real `LicenseRepository` exists yet. Backlog #4 builds it
(SwiftData + `SerialStore`) in a separate run, and #4 also swaps the Release wiring in
`SerialManagerApp.init()`. Nothing in this repository checks the form flow against stored
data.

Defect found: when Delete fails from inside the form, the alert is titled "Couldn't Save
the License" (`LicenseFormView.swift`, shared `errorMessage` alert), while the main window
correctly says "Couldn't Delete the License" (`ContentView.swift`).

## Decisions taken with the owner (2026-11-20)

- D1: this SPEC is written and approved now against the fixed contract; planning and
  implementation start only once #4 is merged into main.
- D2: verification is automated integration tests in CI (real repository from #4, SwiftData
  store, in-memory serial store, never the real Keychain), plus an optional manual checklist
  on a Release build that QA prepares and only the owner runs.
- D3: the form's delete failure gets its own alert title, "Couldn't Delete the License".
  No other view change.

Settled elsewhere and not reopened here (backlog #4): the `LicenseRepository` signature is
fixed; `update` with an empty serial deletes the serial item; `serial(for:)` returns nil for
a missing item and throws only on real Keychain errors; a failed serial write leaves no
half-saved record; Debug builds and previews stay on the fakes.

## In scope

1. Integration tests that drive `LicenseFormModel` and `LicenseStore` over the real
   `LicenseRepository` from #4.
2. The D3 alert title fix, with its Italian translation in `Resources/Localizable.xcstrings`.
3. A manual checklist for a Release build (D2).

## Out of scope

- Implementing `LicenseRepository`, its atomicity and the Release wiring in
  `SerialManagerApp.init()` (all #4).
- Any other change to `LicenseFormView`, `ContentView` or the other views ("do not rewrite
  the views").
- Moving Debug builds or previews off the fakes.
- List and search (#5), detail and clipboard (#7), export and import (#9, #10).
- The known gap that menu commands stay enabled while a sheet is open (`docs/design/gui.md`).

## Prerequisite

P1: #4 is merged into main and this branch (`feature/license-form`) is updated from main.
Updating the branch is a Git write and needs the owner's go-ahead.

## Requirements

Terms: "stored state" means what a NEW repository instance, built on the same
`ModelContainer` and the same serial store, returns from `fetchAll()` and `serial(for:)`.
"Serial store" in tests is `InMemorySerialStore`.

- R1. Cmd+N opens the New License form once the store has loaded from the real repository.
- R2. Saving with an empty or whitespace-only product name is refused with the message
  "Product name is required."; the stored state is unchanged (no record, no serial item).
- R3. Saving a new license with a serial stores the record (trimmed fields, as
  `LicenseDraft.normalized`) and its serial under the record's id.
- R4. Saving an edited license updates the stored record (fields and `updatedAt`) and its
  serial. Clearing the serial field and saving removes the serial item (contract of #4).
  The `serialUnreadable` guard still refuses to save an empty serial when the current one
  could not be read.
- R5. Delete asks for confirmation. Confirming removes both the record and its serial item
  from the stored state; dismissing the confirmation leaves both untouched.
- R6. When a save fails (for example the serial store throws), the form stays open with the
  draft intact, shows "Couldn't Save the License" with the error, and the stored state holds
  no half-saved record.
- R7. When a delete from the form fails, the form stays open, shows "Couldn't Delete the
  License" (D3) with the error, and the license is still in the list and in the stored
  state. The alert for a failed save keeps its current title.
- R8. Cancel, on a new or an edited license, with or without changes, writes nothing: the
  stored state is identical before and after. With changes, "Discard changes?" is asked
  first.
- R9. The integration tests run in the existing unit test target, in CI, without touching
  the real Keychain, and use only obviously fake values (for example `ACME-0000-TEST-0000`,
  `user@example.com`). All existing tests stay green.
- R10. QA writes a manual checklist for a Release build covering R1 to R8, using obviously
  fake values and ending with clean-up steps that delete every entry it creates. The owner
  decides whether to run it; no agent runs it against the owner's Keychain.

## Acceptance examples

- A1 (R1). App launched, list loaded. Press Cmd+N: the "New License" sheet opens with the
  focus on Product Name.
- A2 (R2). New form, Product Name "   ", Serial `ACME-0000-TEST-0000`, Save: the message
  "Product name is required." appears, the sheet stays open, `fetchAll()` is empty and the
  serial store holds 0 items.
- A3 (R3). New form, Product Name " Acme Editor ", Vendor "Acme", Serial
  `ACME-0000-TEST-0000`, Save: a new repository instance returns one record named
  "Acme Editor" and `serial(for: id)` returns `ACME-0000-TEST-0000`.
- A4 (R4). Edit "Acme Editor", Version "4.0", Serial `ACME-1111-TEST-1111`, Save: the stored
  record has version "4.0" and a later `updatedAt`; the serial is `ACME-1111-TEST-1111`.
  Edit again, clear Serial, Save: `serial(for: id)` returns nil.
- A5 (R5). Edit "Acme Editor", Delete License..., Delete: `fetchAll()` no longer contains it
  and the serial store has no item for its id. Same flow but Cancel in the confirmation:
  record and serial are still there.
- A6 (R6). Serial store set to fail, new form "Acme Editor" with a serial, Save: alert
  "Couldn't Save the License", the sheet stays open with the typed values, `fetchAll()` is
  empty.
- A7 (R7). Existing "Acme Editor", serial store set to fail, Delete License..., Delete:
  alert "Couldn't Delete the License", the sheet stays open, the record is still returned by
  `fetchAll()` and listed in the main window.
- A8 (R8). Edit "Acme Editor", change Notes, Cancel, Discard Changes: the stored record and
  serial are byte-for-byte as before. New form, type a name, Cancel, Discard Changes:
  `fetchAll()` count unchanged.

## Verification

| Req | How | Owner of the check |
| --- | --- | --- |
| R1 | Existing command wiring (code review) + manual checklist step | Reviewer, QA, owner |
| R2 | Integration test (A2) | QA on CI result |
| R3 | Integration test (A3) | QA on CI result |
| R4 | Integration tests (A4), plus the existing `unreadableSerialIsNotErasedOnSave` adapted to the real repository | QA on CI result |
| R5 | Integration test for the delete path (A5); confirmation dialog by manual checklist | QA, owner |
| R6 | Integration test with a failing serial store (A6) | QA on CI result |
| R7 | Integration test (A7) for state; alert title by code review and manual checklist; string present in `Localizable.xcstrings` with Italian | Reviewer, QA |
| R8 | Integration test: model edited and never saved leaves stored state unchanged (A8); discard dialog by manual checklist | QA, owner |
| R9 | CI run green on the PR; grep the new tests for real Keychain types and non-fake values | Reviewer, QA |
| R10 | Checklist file delivered and reviewed | QA, owner |

## Open points for planning

- Where the integration tests build the real repository (helper in the test target vs a
  factory shipped by #4): depends on the type and initializer #4 delivers.
- Whether the alert fix needs a second `@State` flag or a small error enum in
  `LicenseFormModel`: the Architect picks the smallest change that meets R7.
