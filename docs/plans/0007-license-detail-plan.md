# Plan: License detail verified on the real Keychain (ticket #7)

- Plan version: v2 (v1, sha256 `65e04abbdc3c`, got CHANGES REQUESTED at PLAN review on 2026-11-20; v2
  folds in findings 1 to 5 and the non-blocking follow-ups, following Stefano's steer of 2026-11-20 on
  the five findings, recorded as D7 to D9 below)
- Date: 2026-11-20
- Input: `docs/specs/0007-license-detail-verification.md` v1.1 (approved by Stefano on 2026-11-20,
  sha256 `4a071884676ffbc1f2b057f9bd40db14ef8ce4d1d74ad62753adc1ee8358b88b`), `docs/design/gui.md`,
  `docs/adr/0003-keychain-implementation.md`, baseline `3352eb6` (= `origin/main`; the branch
  `feature/license-detail` was fast-forwarded to it, no merge commit)
- Author: Architect
- Status: v2, awaiting PLAN re-review

## 0. Decisions from Stefano's steer (2026-11-20)

- D7. One Stefano gate covers commit, push and PR (after CODE APPROVED); merge is a separate gate.
- D8. Stefano grants the Accessibility permission once to the host app that runs the agents, so
  Frontend can watch the menus. If Frontend still cannot drive them, QA checks F5 on a Debug build and
  hands the result back.
- D9. Only the detail's lookup records availability. `LicenseFormModel` reads the serial through a
  non-recording call, so `LicenseDetailView` and `SerialRow` stay untouched (D3).

## 1. Findings that shape the plan

- **F1. Where the detail state lives.** `LicenseDetailView` (`Sources/Views/LicenseDetailView.swift`)
  holds `lookup`, `isRevealed`, `showsCopied` and `copiedResetTask` in `@State`. `ContentView` line 114
  creates it as `LicenseDetailView(license: license, …)` with no identity of its own, so SwiftUI keeps
  the same view, and the same `@State`, when the selection changes. Only `.task(id: TaskKey(id,
  updatedAt))` resets `isRevealed` and `lookup`, and it runs after the new entry has rendered once.
  `showsCopied` is never reset there. This confirms both halves of R6.
- **F2. `.id(_:)` resets state.** The `View.id(_:)` documentation in the macOS 27.2 SDK
  (`SwiftUICore.swiftmodule/arm64e-apple-macos.swiftdoc`, read 2026-11-20) says: "Binds a view's
  identity to the given proxy value. When the proxy value specified by the `id` parameter changes, the
  identity of the view, for example, its state, is reset."
- **F3. A cancelled lookup can still land.** `.task` cancels the old task on an id change, but
  `lookup = await store.serial(for:)` assigns whatever the call returns. `SwiftDataLicenseRepository.serial(for:)`
  forwards to the serial store and does not check cancellation. With `.id`, a late result for entry A
  lands in A's discarded view, not in B's.
- **F4. The menu cannot see the serial today, and the serial has two readers.** `AppCommands` reads
  only `LicenseStore` (`store.selectedLicense == nil`, line 23); the lookup is view state.
  `LicenseStore.serial(for:)` is called by `LicenseDetailView` (line 62) and by `LicenseFormModel`
  (line 40, to prefill the edit form). The menu commands act on the detail's `lookup`
  (`LicenseDetailView.swift` lines 67 and 74), so only the detail's read may drive the menu.
- **F5. Live menu re-evaluation is unverified.** `AppCommands` already reads `@Observable` state
  (`store.phase`, `store.selectedLicense`), but the ticket says nobody has checked the menus in the
  running app. R7 depends on the menu re-evaluating when that state changes. Frontend checks it first
  in T2 (D8); QA checks it in T4a only if Frontend cannot drive the menus.
- **F6. Signed Release build.** The app target signs with Apple Development, team T7H24G7BFW
  (`Project.swift`). ADR 0003 records that `xcodebuild -allowProvisioningUpdates` resolved the team's
  wildcard profile on 2026-11-19; an unsigned or ad-hoc build gets `errSecMissingEntitlement` (-34018)
  from the Keychain.
- **F7. Release opens the real library.** `LicenseLibrary.makeRepository()` uses
  `Application Support/it.stefer.SerialManager/Licenses.store` and the user's Keychain (SPEC D4).
- **F8. `didSet` works on an `@Observable` property.** Prototype run on 2026-11-20 on macOS 27.2.1,
  compiled with `xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`: a `@MainActor @Observable`
  class with `var selection: Int? { didSet { … } }` compiles without warnings; the observer runs on
  every assignment, and `withObservationTracking` on a computed property that reads `selection` fires
  when `selection` changes. Observed on 27.2 only.
- **F9. `load()` can empty the list and keep the selection.** `BackupModels.swift` line 104 calls
  `store.load()` after an import; a failed load sets `licenses = []` but leaves `selection` unchanged
  (`LicenseStore.swift` lines 53 to 65). `selectedLicense` is then nil, `selection` is not.

## 2. Design

### 2.1 R6: one detail view per entry

`ContentView.swift` line 114: add `.id(license.id)` to `LicenseDetailView(…)`, before `.toolbar`.
Nothing else for R6.

Consequences:
- Selecting another entry creates a fresh view: `lookup = .loading`, `isRevealed = false`,
  `showsCopied = false` from the first frame (F2). The previous serial, its revealed state and a
  pending "Copied" cannot render for the new entry.
- Saving the same entry keeps its id, so the view and its state survive, and the existing
  `TaskKey(updatedAt)` reloads the serial and masks it again. A6 relies on this (save from
  "Add Serial…" then the masked serial appears).
- The old view's `copiedResetTask` may still fire and write to the discarded view's state. Harmless;
  no cancel-on-disappear is added.
- Proof without a UI test target: the Reviewer checks that the `.id` is on the detail view and keyed
  by `license.id` only (not `updatedAt`, which would reset on every save); QA runs A8.

Rejected: resetting `showsCopied` inside `.task`. It runs after the first render of the new entry, so
it does not meet "never, even briefly", and it does not stop a late lookup for A (F3).

### 2.2 R7: the store records the detail's serial lookup

`LicenseStore` (`Sources/Store/LicenseStore.swift`) records, inside `serial(for:)`, the detail's lookup,
and exposes one Bool for the menu. The edit form switches to a non-recording read (D9), so the form
(F4) never touches the menu state and `LicenseDetailView` keeps calling `serial(for:)` unchanged.

Shape (names are a suggestion; Frontend may adjust):

```swift
var selection: LicenseSummary.ID? {
    didSet { if selection != oldValue, let selection { detailSerialFound[selection] = nil } }
}

/// Whether the detail found the serial of each entry, as of its last lookup; drives the License menu.
private(set) var detailSerialFound: [LicenseSummary.ID: Bool] = [:]

/// Copy Serial and Show or Hide Serial are enabled only when the detail shows a serial.
var isSelectedSerialAvailable: Bool {
    guard let id = selectedLicense?.id else { return false }
    return detailSerialFound[id] == true
}

/// The serial shown by the detail view. Also records the result for the License menu, so call it
/// only from the detail; other readers use `serialWithoutRecording(for:)`.
func serial(for id: LicenseSummary.ID) async -> SerialLookup {
    detailSerialFound[id] = false
    let result = await serialWithoutRecording(for: id)
    if case .present = result { detailSerialFound[id] = true } else { detailSerialFound[id] = false }
    return result
}

/// The serial, with no effect on the License menu (the edit form's prefill).
func serialWithoutRecording(for id: LicenseSummary.ID) async -> SerialLookup {
    /* the current body of serial(for:) */
}
```

`delete` also removes the entry's key. `save` and `load` do not touch the dictionary: after a save the
detail's `TaskKey(updatedAt)` reloads and records the new state, and a stale key for a removed entry is
never read, because the Bool is guarded by `selectedLicense` (F9).

Last completed call wins, exactly as for the view's `lookup = await …` assignment, so the menu and the
row agree even if two lookups for the same entry overlap (F3, save case).

`AppCommands`: Copy Serial and Show or Hide Serial use `.disabled(!store.isSelectedSerialAvailable)`.
Edit License and Delete License keep `.disabled(noSelection)`.

`LicenseFormModel.swift` line 40: `store.serial(for: license.id)` becomes
`store.serialWithoutRecording(for: license.id)`. `LicenseDetailView` and `SerialRow` are not modified
(D3, D9). Because recording is the default of `serial(for:)`, its doc comment says that only the detail
may call it; I8 and the Reviewer guard this.

Invariants (each one a unit test in T2):
- I1. `selectedLicense` is nil: false. This covers no selection and a selection whose entry is no
  longer in `licenses` (F9: a failed `load()` with a selection previously found present).
- I2. Selected entry, `serial(for:)` returned `.present`: true.
- I3. Selected entry, `serial(for:)` returned `.missing` or `.failed`: false.
- I4. From the start of a `serial(for:)` call until a call for that entry completes: false, even
  if an earlier completed call had found the serial.
- I5. Two overlapping `serial(for:)` calls for the same entry: the Bool reflects the call that
  completed last, whatever the start order.
- I6. Selection changes to an entry: false until a `serial(for:)` for that entry completes after
  the change, including when the entry was found present before (A, then B, then A again).
- I7. After a save that adds a serial to a missing entry and the next `serial(for:)`: true (A6
  path); after a save that empties it and the next lookup: false. After `delete`: false, no key left.
- I8. Opening and cancelling the edit form does not change the Bool: `serialWithoutRecording(for:)` (the
  form's read, through `LicenseFormModel.loadSerial(from:)`) leaves it false after a detail `.failed`
  even when the form read succeeds, and true after a detail `.present` even when the form read fails.

Why the store and not the view: the store is the object both `AppCommands` and the detail already
share, it has a test file, and the logic becomes testable without the GUI (R8). The view's `@State`
stays untouched (D3).

Rejected:
- A `@FocusedValue` published by the detail view: idiomatic, but not unit-testable, and its behaviour
  with a sheet open or the Settings window key is not verified here.
- The view reporting its lookup into `AppRouter`: works, but needs more view code and has less test
  coverage.
- Making the detail reload when the edit form closes: more view code, and a reload on Cancel is visible.

Fallback if F5 fails (the menu does not re-evaluate live): compute the Bool in
`SerialManagerApp.body` and pass it to `AppCommands` as a `let`, like `backupAvailable`; if that also
fails, publish it with `focusedSceneValue` from `ContentView`. The Architect amends 2.2 before T2
starts.

### 2.3 GUI doc

`docs/design/gui.md` line 158, "License commands are disabled without a selection.", becomes:
"License commands are disabled without a selection. Copy Serial and Show or Hide Serial are also
disabled while the selected entry's serial is loading, missing or failed to load."

## 3. Tickets

| Id | Owner | Depends on | Parallel with |
| --- | --- | --- | --- |
| T0 | Git | none | done |
| T4a | QA, preparation (F5 only as fallback) | none | T1, T2 |
| T1 | Frontend | T0 | T4a |
| T2 | Frontend | T0 | T4a |
| T3 | Reviewer (code-reviewer) | T1, T2 | none |
| T3b | Git (engineering-git-workflow-master), one HITL gate Stefano for commit, push and PR (D7) | T3 approved | none |
| T4b | QA, verification | T3b (PR open, CI green), T4a | none |
| T5 | Stefano, fallback checklist (only if T4b hands items over) | T4b | none |
| T6 | Git, HITL gate Stefano: merge | T4b PASS (with T5 if any) | none |

T1 and T2 have one owner and touch different files; they are two commits. A fix requested by T3 goes
back to Frontend, then T3 again. A fix after T4b goes back to Frontend, then T3, T3b (push) and T4b
again on the new PR head.

### T0. Bring the branch to `origin/main` (done)
- `feature/license-detail` fast-forwarded from `b8d6e14` to `3352eb6`, no merge commit (checked by the
  Reviewer at PLAN review, 2026-11-20).

### T4a. QA preparation (starts now)
- Requirements: D4, D5, D6, R3 (marker), R5; F5 for R7 only as the D8 fallback.
- F5 fallback, only if Frontend reports it cannot drive the menus: the T2 F5 check, run by QA on a
  Debug build of `3352eb6`, result handed back through the Lead to Frontend and the Architect.
- Prepare: the Accessibility permission for the agent's driver (Stefano grants it if missing); a Swift
  script in the scratch directory that prints `NSPasteboard.general.types` (run with `xcrun swift
  <script>`), to see `org.nspasteboard.ConcealedType`; the Stefano fallback checklist template (step,
  expected, observed).
- Optional baseline: A8 and A9 on a signed Release build of `3352eb6`, to see them fail before the fix.
  Not required for the verdict.
- QA writes nothing in the working tree: builds go to a `-derivedDataPath` in its scratch directory,
  and it uses the workspace Frontend generated (it asks Frontend if it is missing).

### T1. R6: detail view identity per entry
- Requirements: R6.
- Files: `Sources/ContentView.swift` (one line).
- Expected outcome: section 2.1.
- Verification: `tuist generate --no-open`, build and `xcodebuild … test` (CI command of `docs/ci.md`)
  pass; on a Debug build with fakes, Frontend repeats A8 with the sample entries (reveal, copy, switch
  within 1.5 s) and reports it. A8 on the signed Release build stays with QA (T4b).

### T2. R7: menu commands follow the serial state
- Requirements: R7, R8.
- Files: `Sources/Store/LicenseStore.swift`, `Sources/AppCommands.swift`,
  `Sources/Store/LicenseFormModel.swift` (line 40 only, section 2.2), `Tests/LicenseStoreTests.swift`
  (or a new `Tests/LicenseStoreSerialAvailabilityTests.swift`; a new file needs
  `tuist generate --no-open`), `docs/design/gui.md` line 158.
- First step, F5 (D8): on a Debug build of `3352eb6` (fakes, sample data), read the enabled state of
  License > Edit License from a script with System Events, first with no selection, then after
  selecting an entry. Enabled state that follows the selection proves `AppCommands` re-evaluates on an
  `@Observable` change of `LicenseStore`, the mechanism the fix uses. If it does not follow, stop and
  report: the Architect amends 2.2 with the fallback. If Frontend cannot drive the menus, it asks QA
  for the T4a fallback.
- Expected outcome: sections 2.2 and 2.3.
- Tests: I1 to I3, I6, I7 with `InMemoryLicenseRepository` (`setFailure` for `.failed`); I8 through
  `LicenseFormModel.loadSerial(from:)`, with a failure set only for the form read. For I4 and
  I5, a small test double conforming to `LicenseRepository` whose `serial(for:)` holds each call on its
  own continuation, so the test can release calls one by one and in any order. No real Keychain
  (CLAUDE.md).
- Verification: tests pass; on a Debug build with fakes, Copy Serial and Show or Hide Serial are
  disabled on `SampleData.missingSerial` and enabled on `SampleData.first`, Edit and Delete enabled on
  both. A9 on the signed Release build stays with QA (T4b).

### T3. Code review
- Requirements: R6 (stale-serial half), R7, R8, R9.
- Checks: `.id(license.id)` on the detail and keyed by id only; `LicenseDetailView` and `SerialRow`
  unchanged (D3, D9); `LicenseFormModel` calls `serialWithoutRecording(for:)`, and no caller other than
  the detail calls `serial(for:)` in `Sources/`;
  invariants I1 to I8 in the code and in the tests; `AppCommands` Edit and Delete unchanged;
  `git diff --stat 3352eb6 HEAD` lists only T1 and T2 files plus the SPEC and this plan; no
  real-looking serials in the diff (R9); no change to `LicenseContract.swift`, repositories,
  `Project.swift` or `Localizable.xcstrings`.
- Verification: verdict APPROVED or CHANGES REQUESTED with findings.

### T3b. Commit, push, PR and CI (HITL gate Stefano)
- Requirements: R8.
- Work: after Stefano approves (one gate for commit, push and PR, D7), commit the SPEC (`docs(spec): …`), this plan (`docs(plan): …`) and the
  T1 and T2 changes as separate Conventional Commits on `feature/license-detail`; push; open the PR to
  `main`; wait for the `Build and test` check.
- Verification: PR URL, head SHA and CI result handed to QA and the Lead. T4b tests that head SHA.

### T4b. QA verification on the PR head
- Requirements: R1 to R9.
- Build, on the PR head SHA of T3b:
  1. The CI build and test command of `docs/ci.md`, with a scratch `-derivedDataPath`. All suites pass.
  2. Signed Release build: `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager
     -configuration Release -destination 'platform=macOS' -derivedDataPath <scratch>/qa-0007
     -allowProvisioningUpdates build`, signing on (no `CODE_SIGNING_ALLOWED=NO`).
  3. `codesign -dv --verbose=4 <app>` shows `TeamIdentifier=T7H24G7BFW`, and
     `codesign -d --entitlements - <app>` shows `keychain-access-groups`.
  4. Launch in English (D5): `open -n <app> --args -AppleLanguages "(en)"`.
- Run A1 to A10 of the SPEC. Order: A1 to A5, then create "QA 0007 Empty" (first step of A6), run A9,
  finish A6, then A7, A8, A10. In A7 also check the VoiceOver announcement "Serial copied" after Copy
  (R3, no acceptance example in the SPEC).
- Report per requirement PASS, FAIL (expected versus observed) or BLOCKED, with the SHA tested. Items
  the agent cannot drive go to Stefano as the T5 checklist; QA gives the verdict on both.

### T5. Stefano's checklist (fallback)
- Only the items T4b hands over, with their expected results from the SPEC. Stefano reports the
  observed results to QA.

### T6. Merge (HITL gate Stefano)
- After T4b PASS (and T5 if any), Git merges the PR as the repository does (squash), on Stefano's
  approval, a gate separate from T3b.

## 4. Requirement, ticket and verification

| Req | Ticket | Verification |
| --- | --- | --- |
| R1 | T4b | A1, A2 on signed Release |
| R2 | T4b | A3 |
| R3 | T4b | A4, A5; `pbpaste`; the Swift `NSPasteboard.general.types` check shows the concealed marker; "Serial copied" in A7 |
| R4 | T4b | A6 |
| R5 | T4b | A7 with Accessibility Inspector or VoiceOver |
| R6 | T1, T3, T4b | Reviewer: `.id(license.id)` on the detail (stale-serial half); QA: A8 |
| R7 | T2, T3, T4b | Frontend: F5 check (QA as fallback, T4a); unit tests I1 to I8; Reviewer: `AppCommands`, callers of `serial(for:)`; QA: A9 |
| R8 | T1, T2, T3b, T4b | `xcodebuild … test` by Frontend and QA; CI `Build and test` green on the PR |
| R9 | T3, T4b | Reviewer checks the diff; QA lists the values used and confirms A10 |

## 5. Backend

No Backend work. Evidence: no change to `Sources/Contract/LicenseContract.swift`,
`SwiftDataLicenseRepository`, `KeychainSerialStore`, `LicenseLibrary`, `Project.swift` or
`Resources/Localizable.xcstrings` (no new user-facing string; the gui.md wording is documentation).
`LicenseStore` is GUI state (Frontend, as in #5 and #6).

## 6. Risks

- The Release build opens Stefano's real library (F7). QA must not reveal, copy or screenshot any
  entry whose name does not start with `QA 0007`, and must delete every `QA 0007` entry at the end (R9).
- F5 is unverified until T2's first step; it has a named fallback.
- `serial(for:)` records by default (D9): a future caller other than the detail would drive the menu.
  The doc comment says so and the Reviewer checks the callers.
- `.id` re-creates the whole detail `Form` on every selection change: the scroll position resets
  (wanted) and the toolbar items may be rebuilt; QA notes any visible flicker.
- A cancelled lookup still assigns its result (F3). Within one entry (a save while a read is in flight)
  the row and the menu still agree, both last-writer-wins; the row may show the pre-save value until the
  next lookup. Pre-existing, needs a Keychain read outlasting a modal edit, out of scope. Same class:
  a read from an earlier visit to A that completes after A is selected again sets the Bool for one
  read while the new row still loads; a menu Copy then does nothing (the view guards on its lookup).
- `AppRouter` is shared by every window; multiple windows stay out of scope (`gui.md`).
- Behaviour is observed on macOS 27.2 only; CI runs macOS 26 with Xcode 26.6.
