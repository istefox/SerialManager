# SPEC: License model in SwiftData (backlog #2)

- Version: v1.3 (v1 approved; v1.1 fills A8, which v1 delegated to the Architect; v1.2
  revises R4 per owner decision D3; v1.3 adds the import `restore` path to R4 and R8, as a
  consequence of decision D3 of `docs/specs/0010-encrypted-import.md`)
- Date: 2026-11-21 (v1.3); 2026-11-19 (v1 to v1.2)
- Status: v1.2 approved by the owner on 2026-11-19; v1.3 confirmed by the owner on 2026-11-21
- Related: `docs/adr/0001-storage.md`, `docs/design/gui.md` ("Contract with the data layer"),
  `Sources/Contract/LicenseContract.swift`

## Goal

Every program the owner has bought gets one record with its descriptive data, persisted with
SwiftData. The serial is not part of this record (ADR 0001: serials live in the Keychain).

## Current state (evidence, 2026-11-19, commit 61dd579)

- No SwiftData `@Model` exists yet. `grep` for `@Model`, `ModelContainer`, `SwiftData` in
  `Sources/` and `Tests/` finds only comments. Nothing is persisted today, so no data
  migration is needed.
- The GUI works on the value type `LicenseSummary` and an in-memory fake repository
  (`Sources/Fakes/InMemoryLicenseRepository.swift`). The fake sets `createdAt` and
  `updatedAt` to the same instant on create and bumps `updatedAt` on update.
- `LicenseDraft.normalized` already trims single-line fields, and
  `LicenseDraft.hasValidProductName` already rejects blank names in the form.

## Decisions taken with the owner

- D1: optional text fields (vendor, registered email, version, notes) are non-optional
  `String`, and `""` means "not set". This mirrors `LicenseSummary` 1:1.
- D2: the model itself rejects a product name that is empty or whitespace-only, on creation
  and on update.
- D3 (2026-11-19): SwiftData's reflective write API is accepted as a documented residue of
  R4 (option M2), enforced by a grep at code review, instead of hiding the stored property
  (option M1).

## In scope

A SwiftData model `License` with its validation rules, plus unit tests on an in-memory
`ModelContainer`.

## Out of scope

- The `LicenseRepository` implementation and the `License` to `LicenseSummary` mapping (#4).
- Keychain storage of serials (#3).
- Wiring a `ModelContainer` into `SerialManagerApp` or any view.
- Schema migration (no persisted data exists yet).
- Any change to `Sources/Contract/`, `Project.swift` or GUI files: #3 and #8 are developed in
  parallel worktrees from the same commit, so this ticket adds new files only.

## Requirements

- R1. A SwiftData model `License` exists with exactly these stored fields:
  `id: UUID`, `productName: String`, `vendor: String`, `registeredEmail: String`,
  `purchaseDate: Date?`, `version: String`, `notes: String`, `createdAt: Date`,
  `updatedAt: Date`. Names and types match `LicenseSummary`.
- R2. The model has no field that holds a serial, license key or any derived form of it.
- R3. `productName` is required: creating or updating a `License` with an empty or
  whitespace-only product name fails with a typed error. The other fields may be left empty
  (`""`), and `purchaseDate` may be `nil`.
- R4 (revised in v1.2, decision D3; extended in v1.3). Every stored property is
  `private(set)`: outside the model, the only write paths are the throwing `init`, the
  throwing `update` and the throwing `restore`, all of which apply R3. `restore` exists only
  for the import of a backup that replaces an existing license (SPEC 0010, D3): it sets every
  field and both dates to the backup's values. App code edits a license through `update`. Documented residue: SwiftData's public reflective API
  (`PersistentModel.setValue(forKey:to:)`, `persistentBackingData`) can still write
  `productName` without validation, and no mechanism closes every such path (Architect
  prototype, 2026-11-19). The app code must not use that API on `License`: a grep for
  `setValue(forKey` and `persistentBackingData` outside `Sources/Model/License.swift` must
  print nothing, checked at every code review.
- R5. The model validates but does not rewrite values: a valid product name such as
  `" Example App "` is stored as given. Trimming stays in `LicenseDraft.normalized`.
- R6. `id` is assigned once and never changes. Creation generates a new UUID by default and
  also accepts a caller-supplied UUID, so import (#10) and the mapping in #4 can restore an
  existing entry with its original identity.
- R7. `id` is unique within the store. The Architect confirms how SwiftData on macOS 14
  enforces this and what happens on a duplicate insert before the acceptance check is fixed.
- R8 (extended in v1.3). `createdAt` is set once at creation and never changes, except when
  an import replaces the license with the backup's dates through `restore` (SPEC 0010, D3).
  `updatedAt` equals `createdAt` at creation and is set to the current time on every
  successful update; `restore` sets it to the backup's value instead. Creation accepts
  caller-supplied `createdAt` and `updatedAt` (for import), with "now" as default. A failed
  `restore` (R3) leaves every field unchanged, as R9 requires for `update`.
- R9. A failed update (R3) leaves every field of the entity unchanged, including `updatedAt`.
- R10. Time is injectable (or passed in) so tests check timestamps deterministically, without
  sleeping or comparing against the wall clock.
- R11. Unit tests (Swift Testing) on an in-memory `ModelContainer` cover create, update and
  delete, and the rules above. Tests use only obviously fake sample values
  (for example "Example App", "Acme Corp", "user@example.com").
- R12. `xcodebuild ... build` and `xcodebuild ... test` succeed after `tuist generate --no-open`.

## Acceptance examples

- A1 (create): create `License(productName: "Example App", vendor: "Acme Corp")` at a fixed
  time T, insert, save, fetch. The fetched entity has a non-nil UUID, `productName ==
  "Example App"`, `vendor == "Acme Corp"`, `registeredEmail == ""`, `version == ""`,
  `notes == ""`, `purchaseDate == nil`, `createdAt == T`, `updatedAt == T`.
- A2 (create with identity): create with id U and createdAt T0; after save and fetch, the
  entity has id U and createdAt T0.
- A3 (blank name): creating with `productName` `""` or `"   "` throws the typed error and
  nothing is inserted.
- A4 (update): update the A1 entity at time T+1 with `version = "2.0"`. After save and fetch,
  `version == "2.0"`, `updatedAt == T+1`, `createdAt == T`, `id` unchanged.
- A5 (failed update): update the A1 entity with `productName = "  "`. The call throws, and
  after fetch every field, including `updatedAt`, equals its value before the call.
- A6 (no trimming): create with `productName = " Example App "`; the fetched value is
  `" Example App "`.
- A7 (delete): delete the A1 entity and save; fetching by its id returns nothing and the
  total count drops by one.
- A8 (uniqueness, filled in v1.1 from the Architect's R7 finding in
  `docs/specs/license-model-plan.md`): insert a `License` with id U and save; insert a second
  `License` with the same id U and different values, and save. `save()` does not throw
  (`@Attribute(.unique)` upserts). A fetch by id U in a new `ModelContext` returns exactly one
  entity and the total count is 1. The test does not assert which values survive.

## Verification

| Req | Method |
|-----|--------|
| R1, R2 | Reviewer inspects the model source against `LicenseSummary` |
| R3 | Unit test A3, plus the update case in A5 |
| R4 | Reviewer inspects the model's access control and runs the R4 grep |
| R5 | Unit test A6 |
| R6 | Unit tests A1, A2, A4 |
| R7 | Architect note on SwiftData behaviour, then the A8 test or Reviewer inspection |
| R8, R10 | Unit tests A1, A2, A4 with an injected clock |
| R9 | Unit test A5 |
| R11 | Reviewer and QA read the test file; tests use an in-memory `ModelContainer` only |
| R12 | QA runs `tuist generate --no-open`, then the build and test commands from `CLAUDE.md` |

## Open points

- O1: who commits on `feature/license-model`, and when. The ticket's auto-merge only takes
  committed work, and every commit needs the owner's explicit go-ahead.
- O2: this SPEC file is part of the branch diff. The owner decides whether it stays in
  `docs/specs/` or is dropped before merge.
