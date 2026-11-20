# SPEC: Main window list and search on real data (#5)

Status: v1.1, approved by Stefano on 2026-11-20 (v1.1 adds D4 and D5, decided the same day)
Ticket: #5 "Finestra principale con elenco e ricerca"
Depends on: #4 "Servizio che tiene allineati scheda e seriale" (real `LicenseRepository`)

## Context

The main window (sidebar list, search, empty states, detail pane) is already on `main`
(commit 61dd579: `Sources/ContentView.swift`, `Sources/Views/LicenseListView.swift`,
`Sources/Store/LicenseStore.swift`). It runs on in-memory fakes. Sorting, case-insensitive
search and the empty state are covered by unit tests in `Tests/LicenseStoreTests.swift`
(`loadSortsByNameIgnoringCase`, `searchMatchesNameAndVendorCaseInsensitive`,
`emptyRepositoryIsEmptyState`).

Wiring the real repository into `SerialManagerApp.init()` belongs to #4, which also keeps
Debug builds and previews on the fakes. This ticket verifies the acceptance criteria once
the real repository exists and fixes what fails.

## Decisions (Stefano, 2026-11-20)

- **D1, scope:** #5 does not wire the repository. It verifies the five acceptance criteria
  on top of #4's real `LicenseRepository` and fixes whatever does not pass. Implementation
  starts only once #4 is merged on `main`.
- **D2, verification:** two levels. An automated test drives `LicenseStore` through #4's
  real repository with an in-memory SwiftData container and the in-memory `SerialStore`
  fake. Then a manual check on a Release build with obviously fake entries, across a quit and
  relaunch, deleting the entries from the app at the end.
- **D3, long names:** in the sidebar row, product name and vendor wrap with no line limit.
  No ellipsis, even if a row grows tall.
- **D4, early start for the row:** the row change of D3 (line limits, long-name preview,
  design note) may start before #4 is merged, as an exception to D1. Everything that needs
  the real repository still waits for #4.
- **D5, E7 on Release:** the manual Release check may also create the long-name fake license
  of E7, deleted at the end with the others.

## Scope

In scope:
- An integration test of the list behaviour on #4's real repository (D2).
- Removing the line limits in `LicenseRow` (D3), plus a Debug preview with long names.
- Fixes to existing views only where a requirement below fails.
- A manual verification on a Release build (D2).

Out of scope:
- Wiring the repository in `SerialManagerApp` and choosing the Debug data source (#4).
- Rewriting `ContentView`, `LicenseListView` or `LicenseStore`.
- Create, edit and delete flows (#6), detail pane and serial copy (#7), import and export (#9, #10).
- Any change to the `LicenseRepository` contract in `Sources/Contract/LicenseContract.swift`.

## Requirements

- **R1, list content and order:** the sidebar shows each license's product name and, when
  not empty, its vendor. Rows are sorted by product name, ignoring case
  (`localizedStandardCompare`), whatever order the repository returns.
- **R2, search:** the search field filters on product name or vendor, ignoring case
  (`localizedStandardContains`). A query of only whitespace shows every license.
- **R3, empty state:** with zero licenses the detail pane shows the "No Licenses" state with an
  "Add License" button. The button opens the new-license form.
- **R4, no search results:** with at least one license and a query matching none, the sidebar
  shows the dedicated search-without-results message, not the empty state of R3.
- **R5, minimum size:** at the minimum window size (720 x 440 pt) with the sidebar at its
  minimum width (220 pt), no fixed interface text is truncated, in English and in Italian.
  Product name and vendor in a row wrap with no line limit (D3).
- **R6, persistence:** on a Release build, licenses created in the app are still listed,
  sorted, and searchable after quitting and relaunching it.
- **R7, no regression:** the existing test suite passes and CI is green. Views change only
  where R1 to R5 require it.

## Acceptance examples

Fake data used below (never real products or keys): "zeta Test App" by "Fake Vendor One",
"Alpha Test Tool" by "Example Corp", "Beta Test Suite" by "ACME Fake".

| # | Given | When | Then |
| --- | --- | --- | --- |
| E1 | The three fake licenses | The list loads | Order is Alpha Test Tool, Beta Test Suite, zeta Test App |
| E2 | The three fake licenses | Search "acme" | Only Beta Test Suite (match on vendor) |
| E3 | The three fake licenses | Search "ALPHA" | Only Alpha Test Tool |
| E4 | The three fake licenses | Search "nothing here" | Search-without-results message in the sidebar |
| E5 | The three fake licenses | Search "   " | All three |
| E6 | No licenses | Window opens | "No Licenses" with "Add License"; clicking it opens the form |
| E7 | A license named "Fictional Backup Pro Enterprise Edition Twenty Twenty-Six" by "Example Software Distribution Company" | Window at 720 x 440, sidebar at 220 pt | Both texts wrap in full, no ellipsis |
| E8 | App in Italian, no licenses, then a search without results | Window at 720 x 440 | Every fixed text (title, description, button, search prompt, no-results message) is fully visible |
| E9 | Release build with the three fake licenses | Quit and relaunch | The three licenses are listed in the E1 order; E2 still holds |

## Verification

| Req | Method | Owner (to confirm in the plan) |
| --- | --- | --- |
| R1 | New integration test: E1 through #4's repository (in-memory `ModelContainer`, `InMemorySerialStore`) | Backend |
| R2 | Same test: E2, E3, E5 | Backend |
| R3 | Same test: `store.isEmpty` on an empty container; manual E6 | Backend, QA |
| R4 | Same test: E4 (`visibleLicenses` empty while `licenses` is not); manual E4 | Backend, QA |
| R5 | Preview with long names; manual E7 and E8 with screenshots | Frontend, QA |
| R6 | Manual E9 on a Release build | QA |
| R7 | `xcodebuild … test` locally and the CI `Build and test` check | All |

### Manual check on a Release build (R5, R6)

- Uses the real SwiftData store and the user's login Keychain on Stefano's Mac.
- Only the fake licenses of E1 and E7 (four in all), with fake serials such as `FAKE-0000-TEST`.
- At the end, delete the three licenses from the app. Do not read, change or delete any
  other Keychain item.

## Open questions for the plan

- Name and initializer of #4's repository type, and how the test builds an in-memory
  `ModelContainer` for it.
- Whether #4 is merged on `main` when implementation is due; this branch must be updated
  from `main` first.
