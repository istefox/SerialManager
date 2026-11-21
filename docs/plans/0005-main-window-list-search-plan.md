# Plan: Main window list and search on real data (ticket #5)

- Plan version: v3 (v2 PLAN review CHANGES REQUESTED, 2026-11-20; v3 applies B1, B2, S1 to S4. v2 applied D4
  and D5: T0 split, T2 early start, E7 on Release, section 7 closed)
- Date: 2026-11-20
- Input: `docs/specs/0005-main-window-list-search.md` v1.1 (approved by Stefano on 2026-11-20, decisions D1 to D5),
  `docs/design/gui.md`, `Sources/Contract/LicenseContract.swift`, `docs/ci.md`, baseline `b8d6e14`
- Author: Architect
- Status: draft, for review by the Lead

## 1. Findings that shape the plan

Observed in this worktree at `b8d6e14` on 2026-11-20.

- **F1. Row line limits (D3).** `Sources/Views/LicenseListView.swift`, `LicenseRow`: the product name has
  `.lineLimit(2)` and the vendor `.lineLimit(1)`. These are the only two limits to remove. No other view
  uses `LicenseRow`.
- **F2. Design note contradicts D3.** `docs/design/gui.md`, "Main window" (lines 45 to 47) says the vendor is
  "one line, tail truncation allowed only for the vendor". D3 supersedes it; the note must be updated in the
  same change as the row.
- **F3. Existing coverage is fake-only.** `Tests/LicenseStoreTests.swift` covers sort, case-insensitive search,
  whitespace query and empty state on `InMemoryLicenseRepository`. Nothing exercises `fetchAll()` of a real
  repository, so ordering independence from the repository (R1) is untested today.
- **F4. Store sorts locally on save.** `LicenseStore.save` appends the saved summary and re-sorts locally.
  A test that seeds and asserts on the same store never reads `fetchAll()`; the integration test must assert
  on a fresh `LicenseStore` after `load()`.
- **F5. Fakes and sample data.** `SampleData` and `LicenseStore.preview(...)` are `#if DEBUG`;
  `InMemorySerialStore` is not gated. Tests run in Debug, so both are usable from tests. Existing tests depend
  on the exact content of `SampleData` (first/last names, the "NOWHERE" match), so new data must not be added
  to `SampleData`.
- **F6. In-memory SwiftData container.** `Tests/LicenseModelTests.swift:39` already builds
  `ModelContainer(for: License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`.
  The integration test reuses that pattern.
- **F7. #4 is not implemented yet.** No file in this worktree, nor on `main`, defines a type conforming to
  `LicenseRepository` other than the fake. #4 (run `run-1795163431157-zic9s1`, branch
  `feature/license-repository`, still at `b8d6e14`) is at its Lead step. Its type name and initializer are
  unknown (open question 1 of the SPEC, see section 2).
- **F8. Localized fixed texts exist.** `Resources/Localizable.xcstrings` has Italian values for every fixed
  text of R5: "No Licenses" (Nessuna licenza), "Add License" (Aggiungi licenza), the empty-state description,
  "Name or vendor" (Nome o produttore), "Select a License". The search-without-results text comes from the
  system (`ContentUnavailableView.search(text:)`) and is not in the catalog.
- **F9. CI pitfalls (project memory `ci`).** CI compiles with Xcode 26.6 while the maintainer uses Xcode 27.2;
  any API used must exist on macOS 14 and in the Xcode 26.6 SDK. A plain local `xcodebuild test` passes thanks
  to the local certificate and proves nothing about CI: R7 uses the signing-disabled command in `docs/ci.md`.

## 2. Open questions of the SPEC

1. **Name and initializer of #4's repository type.** Still undecided (F7). The plan assumes a type conforming
   to `LicenseRepository` that is built from a `ModelContainer` and an `any SerialStore`, for example
   `SwiftDataLicenseRepository(container:serials:)`. The assumption is isolated in a single test helper,
   `makeRepository(container:serials:)`, so a different name, a `ModelContext` or a `@ModelActor` changes one
   function. T1 confirms it against merged `main` before writing the tests.
2. **Is #4 merged when implementation is due?** Unknown today: #4 is still at its Lead step. Per D1 no
   ticket that needs the real repository starts before #4 is merged on `main`; T0b updates this branch from
   `main` first. Per D4 the row change (T2) is exempt and starts after the docs commit (T0a).

## 3. Design (fixed by this plan)

### 3.1 Files

| File | Change | Ticket |
|------|--------|--------|
| `Tests/LicenseListIntegrationTests.swift` | New: list behaviour on #4's repository (R1 to R4) | T1 |
| `Sources/Views/LicenseListView.swift` | `LicenseRow` without line limits; Debug preview with long names | T2 |
| `docs/design/gui.md` | "Main window" row description aligned with D3 | T2 |
| `docs/specs/0005-main-window-list-search.md`, this plan | Committed as docs | T0a |

No change to `ContentView.swift`, `LicenseStore.swift`, `LicenseContract.swift`, `SerialManagerApp.swift`,
`SampleData.swift` or `Project.swift`, unless a requirement fails (T5).

### 3.2 Integration test (D2)

- Swift Testing suite `@MainActor struct LicenseListIntegrationTests`.
- Each test builds a fresh in-memory container (F6), an `InMemorySerialStore()` and the repository through
  `makeRepository(container:serials:)`. Only the `LicenseRepository` contract is used after construction.
- Fixture defined in the test file, never from `SampleData` (F5), with the SPEC's fake data:
  "zeta Test App" / "Fake Vendor One" / `FAKE-0000-TEST`, "Alpha Test Tool" / "Example Corp" / `FAKE-0001-TEST`,
  "Beta Test Suite" / "ACME Fake" / `FAKE-0002-TEST`.
- Seeding: `repository.create(_:)` in the unsorted order zeta, Alpha, Beta. Assertions on a **fresh**
  `LicenseStore(repository:)` after `await load()` (F4).
- Tests:
  - `listIsSortedByNameWhateverTheRepositoryOrder` (E1): `phase == .loaded`, names
    `["Alpha Test Tool", "Beta Test Suite", "zeta Test App"]`, vendors carried through unchanged.
  - `searchMatchesVendorIgnoringCase` (E2): `searchText = "acme"` gives `["Beta Test Suite"]`.
  - `searchMatchesNameIgnoringCase` (E3): `"ALPHA"` gives `["Alpha Test Tool"]`.
  - `whitespaceQueryShowsEverything` (E5): `"   "` gives all three, in E1 order.
  - `noSearchResultsIsNotEmptyState` (E4, R4): `"nothing here"` gives `visibleLicenses` empty, `licenses.count == 3`,
    `isEmpty == false`.
  - `emptyContainerIsEmptyState` (R3): no seeding, `isEmpty == true`, `visibleLicenses` empty.
  - `sortIgnoresCaseOnRealRepository` (R1, S1): test-only fixture, fake names only, that discriminates
    case-insensitive from binary order: "Beta Fake Upper" / "ACME Fake" / `FAKE-0004-TEST` created first, then
    "alpha Fake Lower" / "Example Corp" / `FAKE-0005-TEST`. Binary order puts "Beta" first (uppercase sorts
    before lowercase); the expected order is `["alpha Fake Lower", "Beta Fake Upper"]`. The SPEC fixture alone
    cannot tell the two orders apart (Alpha, Beta, zeta is the same in both).
  - `listSurvivesAStoreReload` (automated proxy for R6): three `save` calls on one `LicenseStore` (one per
    SPEC fake license), then a second repository over the **same** container and serial store, a fresh
    `LicenseStore`, `load()`: E1 order. If #4's type cannot share a container between two instances, drop this test and note it; R6 is
    still verified manually (T4).
- Never the real Keychain, never `KeychainSerialStore` (CLAUDE.md, plan 0003 R11).

### 3.3 Row (D3)

- Remove `.lineLimit(2)` from the name and `.lineLimit(1)` from the vendor. Nothing else in the row changes
  (font, colour, spacing, accessibility).
- Add a `#if DEBUG` preview "List, long names" in `LicenseListView.swift` with a local store built from
  `LicenseStore.preview(entries:)` containing the E7 license ("Fictional Backup Pro Enterprise Edition Twenty
  Twenty-Six" by "Example Software Distribution Company") plus one short entry, inside a `NavigationSplitView`
  whose sidebar is at its 220 pt minimum. Data local to the preview, not in `SampleData` (F5).
- Removing the limit is expected to wrap in a macOS sidebar `List`, but this is not asserted from memory: E7 on
  the rendered preview decides. Fallback if the text still truncates: `.fixedSize(horizontal: false,
  vertical: true)` on each `Text` (available since macOS 10.15). Any API used must build with Xcode 26.6 (F9).
- `gui.md`: replace "(secondary, one line, tail truncation allowed only for the vendor)" with wording that both
  texts wrap with no line limit (D3).

## 4. Tickets

| Id | Title | Owner | Depends on | Parallel with |
|----|-------|-------|------------|---------------|
| T0a | Commit SPEC + plan locally | Git | none (now) | none |
| T0b | Update branch from `main` after #4 | Git | #4 merged on `main`, T0a | T2 |
| T1 | Integration test on #4's repository | backend | T0b | T2 |
| T2 | Row without line limits, long-name preview, gui.md | frontend | T0a only (D4) | T0b, T1 |
| T3 | Combined build and test, scope check | backend | T1, T2 | none |
| T6 | Review | code-reviewer | T3, T2 preview screenshot | none |
| T4 | Manual check on a Release build (Stefano drives, QA judges) | qa | T6 APPROVED | none |
| T5 | Fixes, only for a failed requirement | frontend (views) / backend (store, tests) | T3, T6 or T4 failure | none |
| T7 | Push and open the PR, CI check | Git | T4 passed, Stefano's explicit authorization (HITL) | none |

T1 and T2 touch disjoint files and run in parallel. Per D4, T2 starts right after T0a, before #4 is merged;
T1 waits for T0b. If T2's commits land before T0b, T0b carries them onto the updated `main`.
Order after T1 and T2: T3, then T6, then T4 (only on T6 APPROVED), then T7. A T5 fix gets a delta T6 review
before the affected T3 checks and T4 steps rerun.

### T0a. Docs commit (now)

- SPEC: D1, D4. Owner: Git. Authorized by Stefano on 2026-11-20: local commit only, no push.
- Commit the SPEC and this plan on `feature/main-window-list-search`
  (`docs: add SPEC and plan for main window on real data (#5)`).
- Verification: `git log -1 --stat` lists exactly the two docs files; `git status` clean for them.

### T0b. Update from `main` after #4

- SPEC: D1, R7. Owner: Git.
- After #4 is merged on `main`: `git fetch` and update the branch from `origin/main`. The branch is not pushed
  yet, so a rebase is safe; once pushed, merge `main` instead (never force-push).
- Verification: `git log` shows #4's merge commit as an ancestor; `tuist generate --no-open` and the
  `docs/ci.md` test command pass before T1 starts.

### T1. Integration test (D2)

- SPEC: R1, R2, R3, R4, (R6 automated proxy). Files: `Tests/LicenseListIntegrationTests.swift` only.
- First step: read #4's merged code, confirm type name and initializer, write `makeRepository` accordingly
  (section 2, question 1). Report the actual signature in the ticket.
- Outcome: design 3.2.
- Record in the ticket the order `fetchAll()` of #4 actually returns (unsorted, insertion order, sorted by name
  binary or case-insensitive), read from #4's code and observed in the test.
- Verification: the eight tests pass with the `docs/ci.md` command. Local sanity check, never committed:
  temporarily drop `Self.sorted` in `LicenseStore.load()` and confirm `listIsSortedByName...` and
  `sortIgnoresCaseOnRealRepository` fail. The check is meaningful only if `fetchAll()` does not already return
  a case-insensitive name order; if it does, record that the check cannot discriminate and that the store's
  sort stays covered by `loadSortsByNameIgnoringCase` on the fake (`Tests/LicenseStoreTests.swift`).

### T2. Row and preview (D3)

- SPEC: R5 (row part), D3, D4. Files: `Sources/Views/LicenseListView.swift`, `docs/design/gui.md`.
- Starts after T0a, on the current base `b8d6e14` (D4); it uses only the fakes, never #4's code.
- Outcome: design 3.3.
- Verification: preview "List, long names" rendered (Xcode preview or `RenderPreview`) at sidebar 220 pt shows
  both E7 texts in full, no ellipsis; screenshot attached to the ticket. Existing previews still render.
  Commits: `feat(gui): let license rows wrap long names` and `docs(design): align row wrapping with D3`
  (or one commit if the Git owner prefers).

### T3. Combined build and test

- SPEC: R7. No new files.
- Verification:
  - `tuist generate --no-open`, then the signing-disabled test command in `docs/ci.md` passes; the new suite
    ran (8 tests) together with the existing ones.
  - `xcodebuild ... -configuration Release build` succeeds (needed by T4).
  - Scope: `git diff origin/main -- Sources/ContentView.swift Sources/Store/LicenseStore.swift
    Sources/Contract/LicenseContract.swift Sources/SerialManagerApp.swift Sources/Fakes/SampleData.swift
    Project.swift` is empty (unless T5 justified a change).
  - Fake data only: new strings are the SPEC's fake names, the S1 fixture names, vendors and `FAKE-...-TEST`
    serials.
  - The CI check moved to T7 (no push before Stefano authorizes it, D6).

### T4. Manual check on a Release build (D2)

- SPEC: R3 (E6), R4 (E4), R5 (E7, E8), R6 (E9). Agents cannot drive the GUI on this Mac (no Accessibility):
  QA writes the script and the expected results, **Stefano drives the app** and sends screenshots, QA judges
  them and records pass/fail per example.
- Build: `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -destination 'platform=macOS'
  -configuration Release -derivedDataPath build/DerivedData build`; app at
  `build/DerivedData/Build/Products/Release/SerialManager.app`.
- Starts only after T6 is APPROVED.
- Stop conditions:
  - Before starting: the Release list must be empty. If it is not (Stefano already has real licenses), do not
    delete or touch them: skip E6/E8-empty on Release and check them on the "Main, empty" preview instead,
    and do the remaining steps without deleting anything that is not one of the fake entries. The preview
    cannot verify that clicking "Add License" opens the form: QA marks that part of E6 explicitly as a
    residual gap in the T4 report, not as passed.
  - At the end: the fake entries created here are deleted from the app (which removes their serials through
    #4). No other Keychain item is read, changed or deleted.
- Script:
  1. Launch in Italian: `open -n <app> --args -AppleLanguages '(it)' -AppleLocale it_IT`. Resize the window to
     its minimum (720 x 440) and drag the sidebar to its minimum (220 pt). **E6 + E8 (empty):** "Nessuna
     licenza", its description and "Aggiungi licenza" fully visible, the search prompt "Nome o produttore"
     fully visible; click "Aggiungi licenza": the new-license form opens; cancel. Screenshot.
  2. Create the three fake licenses (serials `FAKE-0000-TEST`, `FAKE-0001-TEST`, `FAKE-0002-TEST`).
     **E1:** order Alpha, Beta, zeta. Search "acme" (**E2**), "ALPHA" (**E3**), "   " (**E5**).
  3. Search "nothing here". **E4 + E8 (no results):** the system no-results message is in the sidebar (not the
     empty state) and fully visible at 220 pt in Italian. Screenshot.
  4. **E7:** create the long-name fake license of the SPEC (D5: four fake licenses in total, serial
     `FAKE-0003-TEST`), check both texts wrap in full at 220 pt. Screenshot.
  5. Quit (Cmd+Q) and relaunch the Release app. **E9:** the licenses are listed in E1 order, E2 still holds.
  6. Delete every fake license created in steps 2 and 4 from the app. The list returns to its starting state.
- Repeat step 1 and step 3 in English (plain `open -n <app>`) for R5 "in English and in Italian".
- Steps 2 and 6 use today's create and delete flows. #6 (`feature/license-form`) is in progress: if #6 merges
  on `main` before T4 ends, update the branch from `main` (as in T0b), rerun T3, and rerun steps 2 and 6 on the
  updated flows.
- Any truncated fixed text or wrong state opens a T5 fix limited to the view concerned.

### T5. Fixes (conditional)

- Only when T3, T6 or T4 shows a requirement failing. The fix cites the failing requirement and example,
  touches only the view or store concerned, adds or adjusts a test where the behaviour is testable, gets a
  delta T6 review, then re-runs T3 and the affected T4 steps. A fix that would change approved behaviour or the
  `LicenseRepository` contract goes to the Lead for Stefano instead.

### T6. Review

- Depends on T3 and on the T2 preview screenshot. T4 starts only on T6 APPROVED. A T5 fix gets a delta review
  of its own diff before the affected T4 steps rerun.
- Reviewer checks: test helper isolates #4's type (3.2); assertions on a fresh store after `load()` (F4);
  the S1 fixture discriminates binary from case-insensitive order; #4's `fetchAll()` order recorded (T1);
  no `KeychainSerialStore` or `.live` in `Tests/`; row diff limited to the two removed limits plus the preview;
  `gui.md` aligned with D3; scope diff of T3 empty; fake data only; APIs available on macOS 14 / Xcode 26.6.

### T7. Push and PR (HITL)

- SPEC: R7. Owner: Git. Starts only after T4 passed and **Stefano explicitly authorizes the push** (D6 forbids
  it today; the gate is never assumed).
- Push with `git push -u origin feature/main-window-list-search` (never force), open the PR to `main`.
- Verification: the CI `Build and test` check is green on that PR. A red check opens a T5 fix. Merge is out of
  scope of this plan (Stefano's explicit go-ahead, project memory `git-workflow`).

## 5. Requirement to verification

| Req | Ticket | Method |
|-----|--------|--------|
| R1 | T1, T4 | `listIsSortedByNameWhateverTheRepositoryOrder` (E1, fresh store), `sortIgnoresCaseOnRealRepository`; manual E1, E9 |
| R2 | T1, T4 | `searchMatchesVendorIgnoringCase` (E2), `searchMatchesNameIgnoringCase` (E3), `whitespaceQueryShowsEverything` (E5); manual E2, E3, E5 |
| R3 | T1, T4 | `emptyContainerIsEmptyState`; manual E6 including the form opening (residual gap if the Release list is not empty) |
| R4 | T1, T4 | `noSearchResultsIsNotEmptyState` (E4); manual E4 screenshot |
| R5 | T2, T4 | Long-name preview at 220 pt; manual E7 and E8 screenshots, Italian and English |
| R6 | T1, T4 | `listSurvivesAStoreReload` (proxy); manual E9 on Release across quit and relaunch |
| R7 | T3, T6, T7 | `docs/ci.md` test command, Release build, scope diff (T3); CI `Build and test` green on the PR (T7) |

## 6. Risks and coordination

- **#4 timing and shape.** Everything except T0a and T2 waits for #4 on `main` (D1, D4). If #4's repository
  needs more than a container and a serial store (a clock, a logger), `makeRepository` absorbs it.
- **Release store location (for #4, to verify there).** The app is not sandboxed. A default
  `ModelConfiguration` may place the store in a location shared with other non-sandboxed apps (unverified
  here, check the SwiftData documentation in #4). T4 assumes #4 chose an app-specific store URL; if not,
  T4 step 6 must still delete only the fake entries.
- **System text in R5.** The no-results text of `ContentUnavailableView.search` is not ours (F8). If it
  truncates in the 220 pt sidebar, the fix options (custom `ContentUnavailableView` with our own localized
  strings) change `LicenseListView`'s overlay, still within "fixes to existing views where a requirement
  fails", but the wording becomes ours: the Lead confirms the wording with Stefano before T5.
- **Parallel tickets.** #6 (`feature/license-form`) and #7 (`feature/license-detail`) may touch
  `ContentView.swift` or the form; this ticket does not, so conflicts are limited to `LicenseListView.swift`
  if #6 adds a context menu there. Whoever merges second rebases.
- **macOS 14 behaviour.** No macOS 14 runner exists (project memory `ci`); wrapping and the empty states are
  checked on the maintainer's macOS only.

## 7. Questions for the Lead (closed)

Both v1 questions were answered by Stefano on 2026-11-20 and recorded in SPEC v1.1:

1. **Early start of T2:** D4, T2 starts after T0a, before #4 is merged. T1 and everything that needs the real
   repository still wait for #4.
2. **E7 on Release:** D5, the Release check may create the E7 long-name fake license too (four fake licenses
   in total), deleted at the end with the others (T4 step 6).
