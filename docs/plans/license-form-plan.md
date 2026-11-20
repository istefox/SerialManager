# Plan: Create, edit and delete a license on persistent data (ticket #6)

- Plan version: v1.1 (v1 sent to the Lead 2026-11-20; v1.1 follows SPEC v1.1 (Q1 closed), Reviewer B1 and A5)
- Date: 2026-11-20
- Input: `docs/specs/license-form.md` v1.1 (v1 approved by Stefano on 2026-11-20; v1.1 records his Q1 answer), `docs/design/gui.md`,
  `Sources/Contract/LicenseContract.swift`, `docs/plans/0004-license-repository-plan.md`,
  baseline `0e49d60` (`feature/license-form`, merge of `main` at `3352eb6` into `4da9ca6`)
- Author: Architect
- Status: v1.1, waiting for PLAN re-review

## 1. Findings that shape the plan

All read in this worktree at `0e49d60` on 2026-11-20. Nothing below was run; build and tests run in the tickets.

- **F1. The real repository and how tests build it (SPEC open point 1, answered).** #4 delivers
  `actor SwiftDataLicenseRepository: LicenseRepository, ModelActor` in
  `Sources/Data/SwiftDataLicenseRepository.swift`, with
  `init(modelContainer:serials:makeID:now:beforeSave:)`. Each instance creates its own `ModelContext` with
  autosave off and saves explicitly after every mutation. The #4 tests already build it in the test target
  with `ModelContainer(for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`
  and read the stored state through a fresh `ModelContext(container)` (`Tests/SwiftDataLicenseRepositoryTests.swift`,
  `makeContainer` and `stored(in:)`, lines 61 to 86). #6 builds it the same way, in a private helper in its
  own test file. No factory from #4 is needed.
- **F2. `LicenseLibrary.makeRepository()` must never appear in tests.** Its defaults are
  `LicenseLibrary.defaultStoreURL` (the owner's real library under Application Support) and
  `KeychainSerialStore()` (the real Keychain) (`Sources/Data/LicenseLibrary.swift`). The R9 grep covers it.
- **F3. Serial store double: `InMemorySerialStore`, as the SPEC says.** `ScriptedSerialStore`
  (`Tests/Support`) fails one operation at a time, but the SPEC fixes `InMemorySerialStore`, and A2 to A8
  can all be written with it. Its `setFailure` makes EVERY operation throw, reads included, so:
  - in A7, set the failure after `loadSerial`, otherwise the form ends up `serialUnreadable`;
  - clear the failure (`setFailure(nil)`) before reading the stored state;
  - `itemCount` gives "the serial store holds 0 items" for A2 and A6.
- **F4. The injected error must not be `SerialStoreError.undecodableData`.** `readPreviousSerial`
  treats that case as "unreadable" and goes on with the change (#4, D9). Any other error (a local
  `struct InjectedFailure: Error`, or `SerialStoreError.accessDenied`) stops `update` and `delete` before any
  write. In A7 the delete fails on its first call, the serial read, so record and serial stay. That meets
  R7. Tests assert `errorMessage != nil`, never its text: #4 gave `accessDenied` a dedicated message.
- **F5. #4's decisions agree with R6 and R7.** An edit whose serial write fails is all-or-nothing, and a
  delete that the Keychain refuses is blocked with an alert (#4 decisions, 2026-11-20). R6 and R7 add no
  behaviour on top of #4. They check that the form and `LicenseStore` keep the draft, the list and the
  sheet consistent with that behaviour.
- **F6. Fixed clock per instance.** `now` is fixed when a repository is built. A4 needs a later
  `updatedAt`, so the test injects a controllable clock: a small test-only class holding a date behind
  `OSAllocatedUnfairLock` (macOS 13+; `Synchronization.Mutex` needs macOS 15), passed as
  `now: { clock.date }`, and moved forward between the save and the edit. Do not use a second writer
  instance at a later date instead: one store keeps writing through one repository instance per test.
  Stored state is always read through a NEW instance (or a fresh `ModelContext`) built at assertion time.
- **F7. D3 smallest change (SPEC open point 2, answered).** `LicenseFormModel.errorMessage` is set in
  three places: the `serialUnreadable` guard in `save`, the `catch` in `save`, and the `catch` in `delete`.
  The view shows a single alert titled "Couldn't Save the License" (`Sources/Views/LicenseFormView.swift`,
  line 52). The smallest change that meets R7:
  - add to the model `enum FailedAction { case save, delete }` and `private(set) var failedAction: FailedAction = .save`;
  - set it at ALL three places (`.save` at the first two, `.delete` at the third), so a failed save after a
    failed delete never shows the delete title;
  - keep `errorMessage` settable as it is, so the alert binding and the "Form, save error" preview stay
    untouched;
  - in the view, choose the title with a `switch` or `if` between two literal titles, each built as
    `Text("Couldn't Save the License")` and `Text("Couldn't Delete the License")`, and pass it to
    `.alert(_: Text, isPresented:actions:message:)`. Do not compute a `String` title: the `StringProtocol`
    overload does not localize, and the Italian entry would be skipped.

  Both keys already exist in `Resources/Localizable.xcstrings` with Italian
  ("Impossibile salvare la licenza", "Impossibile eliminare la licenza"), so the catalog needs no change.
- **F8. Commands.** Cmd+N is `Button("New License")` with `.keyboardShortcut("n")`, disabled while
  `store.phase != .loaded` (`Sources/AppCommands.swift`). R1 needs no code: a store loaded from the real
  repository reaches `.loaded`, and the rest is code review plus the manual checklist.
- **F9. No project change.** A new file under `Tests/` is picked up by the `Tests/**` glob in
  `Project.swift`: run `tuist generate --no-open`, never edit `Project.swift` or the `.xcodeproj`.
- **F10. A Release build now uses the owner's real data.** Since #4, Release opens
  `Application Support/<bundle id>/Licenses.store` and the real Keychain
  (`SerialManagerApp.init()` calls `LicenseLibrary.makeRepository()`). The R10 checklist therefore runs on
  the owner's real library: it must create only fake entries, touch only those, and delete them at the end.

## 2. Design

### 2.1 Integration test file

New file `Tests/LicenseFormIntegrationTests.swift`, `@MainActor struct LicenseFormIntegrationTests`, Swift
Testing. Private helpers:

- `makeContainer()`: in-memory `ModelContainer` for `License` (as in F1).
- `TestClock`: a test-only, `Sendable` class that holds a date behind `OSAllocatedUnfairLock` (F6).
  `advance(by:)` moves it forward.
- `makeStore(container:serials:clock:) async -> LicenseStore`: builds `SwiftDataLicenseRepository` with the
  container, the `InMemorySerialStore` and `now: { clock.date }`, wraps it in a `LicenseStore`, then
  calls `await store.load()`.
- `storedState(container:serials:) async throws -> ([LicenseSummary], [UUID: String?])`: builds a NEW
  `SwiftDataLicenseRepository` on the same container and serial store, then returns `fetchAll()`
  (sorted by id) and `serial(for:)` for each id. This is the SPEC's "stored state". Call it only after any
  injected failure has been cleared.
- Fake values only: `ACME-0000-TEST-0000`, `ACME-1111-TEST-1111`, "Acme Editor", "Acme",
  `user@example.com`. Fixed dates from `Date(timeIntervalSinceReferenceDate:)`.

Tests drive `LicenseFormModel.save(to:)`, `delete(from:)` and `loadSerial(from:)` against a `LicenseStore`
built on the real repository. Repository-level atomicity is already covered by #4's tests, so these tests
do not repeat it. They check the path form, then store, then repository, then stored state.

| Test | SPEC | What it checks |
| --- | --- | --- |
| `loadsFromRealRepository` | R1 | Empty store reaches `.loaded` (Cmd+N enable condition) |
| `blankNameStoresNothing` | R2, A2 | `save` returns false, `showsNameError`, stored state empty, `itemCount == 0` |
| `newLicenseStoresTrimmedRecordAndSerial` | R3, A3 | One record "Acme Editor", vendor "Acme", `serial(for:)` = `ACME-0000-TEST-0000` |
| `editUpdatesRecordAndSerial` | R4, A4 | After `clock.advance`, version "4.0", `updatedAt` later than before, serial `ACME-1111-TEST-1111` |
| `clearingSerialRemovesItem` | R4, A4 | Edit with empty serial, `serial(for:)` nil, `itemCount == 0` |
| `unreadableSerialIsNotErasedOnRealRepository` | R4 | New test, existing one stays as is: failure set, `loadSerial`, failure cleared, `save` refused, serial still stored |
| `deleteRemovesRecordAndSerial` | R5, A5 | `delete` returns true, record gone from the stored state and from `store.licenses`; the serial item is checked directly, `serials.serial(for: id) == nil` and `itemCount == 0` (the stored-state helper only reads ids returned by `fetchAll()`, so it cannot see an orphan serial) |
| `failedSaveKeepsDraftAndStoresNothing` | R6, A6 | Draft WITH a serial (an empty one never calls the serial store, so nothing would fail), failure set, `save` false, `errorMessage != nil`, draft unchanged, after clearing: stored state empty |
| `failedEditKeepsStoredRecord` | R6 | Existing record, `loadSerial`, failure set, edit + `save` false, after clearing: stored state as before |
| `failedDeleteKeepsRecordAndSerial` | R7, A7 | `loadSerial`, failure set, `delete` false, `errorMessage != nil`, record still in `store.licenses` and, after clearing, in the stored state with its serial |
| `cancelledEditWritesNothing` | R8, A8 | `loadSerial`, change notes, drop the model: stored state equal before and after (`LicenseSummary` is `Hashable`, compare values) |
| `cancelledNewWritesNothing` | R8, A8 | New model, type a name, drop it: `fetchAll()` count unchanged |

"Cancel" and "dismissed confirmation" are view actions that never call the model. The model-level proxy
is "the model is never saved or deleted". The dialogs themselves are checked in the manual checklist.

### 2.2 D3 unit tests

In `Tests/LicenseFormModelTests.swift` (in-memory fakes, existing file, existing tests untouched):

- a failing delete sets `failedAction == .delete` and `errorMessage != nil`;
- a failing save sets `failedAction == .save`;
- the `serialUnreadable` guard sets `failedAction == .save`;
- a failed delete followed by a failed save leaves `failedAction == .save`.

### 2.3 Release checklist (R10)

File `docs/qa/license-form-release-checklist.md` (new `docs/qa/` folder). QA writes the content and
frontend commits it as a file (Lead's decision). Content:

- prerequisites: a Release build signed as described in `docs/adr/0003-keychain-implementation.md`;
- a warning that the build opens the owner's real library and Keychain (F10);
- steps for R1, R2, R3, R4, R5 (confirm and dismiss) and R8 (both discard paths);
- a note that R6 and R7 (including the D3 alert title) are covered by the automated tests and code review,
  not by hand, because a Release build has no safe way to make the real Keychain or SwiftData fail on
  demand (SPEC v1.1, Q1);
- clean-up steps that delete every entry the checklist created, then check that none is left.

Only obviously fake values. The owner decides whether to run it, and no agent runs it.

## 3. Tickets

### T1. D3: form delete failure gets its own alert title

- Owner: frontend
- SPEC: R7 (title), D3
- Depends on: nothing (P1 done)
- Files: `Sources/Store/LicenseFormModel.swift`, `Sources/Views/LicenseFormView.swift` (alert title only),
  `Tests/LicenseFormModelTests.swift`
- Work: section 1, F7, and section 2.2. No other view change, no new preview, catalog untouched.
- Expected outcome: a failed delete in the form shows "Couldn't Delete the License" (Italian: "Impossibile
  eliminare la licenza"). A failed save, including the unreadable-serial refusal, keeps "Couldn't Save the
  License".
- Verification: `xcodebuild … build` and `… test` green; the four tests in 2.2 pass. The Reviewer checks
  that both titles reach `.alert` as `Text` built from literals, and that the diff of
  `LicenseFormView.swift` is limited to the alert title.

### T2. Integration tests over the real repository

- Owner: backend
- SPEC: R1 to R9 (state side)
- Depends on: nothing (P1 done)
- Files: new `Tests/LicenseFormIntegrationTests.swift` only
- Work: section 2.1, after `tuist generate --no-open`. No change to sources, fakes or existing tests.
- Expected outcome: the 12 tests in 2.1 pass on an in-memory container with `InMemorySerialStore`.
- Verification: `xcodebuild … test` green, with the full suite (existing tests included) still passing.
  Self-check before handing over:
  `grep -nE "KeychainSerialStore|KeychainClient|SecItem|makeRepository|defaultStoreURL|undecodableData" Tests/LicenseFormIntegrationTests.swift`
  returns nothing. Every string literal is an obviously fake value.

### T3. Release manual checklist

- Owner: qa (content) and frontend (writes the file)
- SPEC: R10 (v1.1: R1 to R5 and R8 by hand, R6 and R7 as a note)
- Depends on: nothing.
- Files: new `docs/qa/license-form-release-checklist.md`
- Work: section 2.3. QA sends the final text to frontend, and frontend writes it verbatim.
- Expected outcome: a checklist the owner can run in about 10 minutes, ending with no fake entry left.
- Verification: the Reviewer reads it against R1 to R5, R8, the R6/R7 note and F10. QA confirms that the committed file matches
  its text.

### T4. Combined verification

- Owner: qa (read-only: runs and reads, edits nothing), with the Reviewer for code review
- SPEC: R1 to R10, verification table
- Depends on: T1, T2, T3
- Work:
  - `tuist generate --no-open`, then `xcodebuild … build` and `xcodebuild … test` on the combined branch;
  - the R9 grep from T2 over `Tests/LicenseFormIntegrationTests.swift`, plus a check that the new tests use
    only fake values;
  - a check that every row of the SPEC verification table has its evidence (test name, review note or
    checklist step);
  - `git diff 0e49d60 --stat` lists only the files of T1 to T3 plus this plan;
  - CI green on the PR (after Stefano approves the Git steps).
- Expected outcome: a QA verdict mapping each of R1 to R10 to its evidence.

Git steps (commit, push, PR) are not tickets of this plan. They go to Git, one approval from Stefano each.

## 4. Parallelism

T1, T2 and T3 start together. They touch disjoint files:

- T1: the model, the view and the existing model tests;
- T2: one new test file;
- T3: one new doc.

T2 does not depend on T1 for its content: A7 checks state only, and T1 tests the alert title.

**Build and test runs are serialized (Reviewer B1).** T1 and T2 share the only worktree
(`.worktrees/feature-license-form`), so an `xcodebuild` run by one agent would compile the other's
half-done edits and share the same DerivedData. Edits go in parallel; `tuist generate`, `xcodebuild build`
and `xcodebuild test` do not. Order set by the Lead: frontend (T1) runs first and reports green, then
backend (T2) runs its build and tests on top of it. The two may agree on other turns, but never run at
the same time. T3 runs no build.

T4 waits for all three.

## 5. Requirement coverage

| Req | Ticket | Evidence |
| --- | --- | --- |
| R1 | T2, T3, T4 | `loadsFromRealRepository`; review of `AppCommands`; checklist step |
| R2 | T2 | `blankNameStoresNothing` |
| R3 | T2 | `newLicenseStoresTrimmedRecordAndSerial` |
| R4 | T2 | `editUpdatesRecordAndSerial`, `clearingSerialRemovesItem`, `unreadableSerialIsNotErasedOnRealRepository` |
| R5 | T2, T3 | `deleteRemovesRecordAndSerial`; confirmation and dismissal by checklist |
| R6 | T2, T3 | `failedSaveKeepsDraftAndStoresNothing`, `failedEditKeepsStoredRecord`; checklist note (not by hand) |
| R7 | T1, T2, T3 | `failedDeleteKeepsRecordAndSerial`; 2.2 tests and code review for the title (not by hand, SPEC v1.1 Q1); catalog entry present; checklist note |
| R8 | T2, T3 | `cancelledEditWritesNothing`, `cancelledNewWritesNothing`; discard dialog by checklist |
| R9 | T2, T4 | CI green; grep; fake values |
| R10 | T3, T4 | Checklist file reviewed |

## 6. Open points for the Lead

None open.

- **Q1, closed (Stefano, 2026-11-20: "Solo test e review").** R6 and R7 are verified by automated tests
  and code review only; the checklist states it and why (SPEC v1.1). The R7 title is checked by the T1
  unit tests and review.
- **Note, not a ticket.** `origin/main` moved to `4251d89` (#7). Before the PR, `feature/license-form` needs
  one more update from `main`: a Git step for Git, with Stefano's approval. T4 runs on the updated branch.
