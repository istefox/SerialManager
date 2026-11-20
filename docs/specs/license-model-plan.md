# Plan: License model in SwiftData (backlog #2)

- Input: `docs/specs/license-model.md` v1.2 (v1 approved by the owner on 2026-11-19, v1.1
  fills A8, v1.2 revises R4), decisions D1, D2, D3
- Base: commit 61dd579, branch `feature/license-model`
- Author: Architect, 2026-11-19
- Plan version: v3 (v2 addressed Reviewer PLAN review B1, B2, B3; v3 applies D3: M2)
- Status: draft for Lead review. Implementation starts only after the Lead assigns it.

## Summary

One backend ticket adds two new files: the SwiftData model and its tests. No existing file
changes. Frontend has no work: the SPEC excludes GUI changes and wiring a `ModelContainer`
into the app. Reviewer and QA then verify the combined result.

## Files

| File | Status | Content |
|------|--------|---------|
| `Sources/Model/License.swift` | new | `@Model final class License`, `LicenseValidationError` |
| `Tests/LicenseModelTests.swift` | new | Swift Testing suite on an in-memory `ModelContainer` |

`Project.swift` already globs `Sources/**` and `Tests/**`, so `tuist generate --no-open`
picks up both files without editing `Project.swift`. Nothing under `Sources/Contract/`,
`Sources/Views/`, `Sources/Store/` or `Sources/Fakes/` changes.

## Model design

```swift
import Foundation
import SwiftData

/// Why a `License` refused a value.
enum LicenseValidationError: Error, Equatable {
    /// The product name is empty or contains only whitespace.
    case emptyProductName
}

/// Descriptive data of one license. The serial is not stored here (ADR 0001).
@Model
final class License {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var productName: String
    private(set) var vendor: String
    private(set) var registeredEmail: String
    private(set) var purchaseDate: Date?
    private(set) var version: String
    private(set) var notes: String
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Throws `LicenseValidationError.emptyProductName` for a blank name.
    /// `updatedAt` defaults to `createdAt`.
    init(
        id: UUID = UUID(),
        productName: String,
        vendor: String = "",
        registeredEmail: String = "",
        purchaseDate: Date? = nil,
        version: String = "",
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) throws

    /// Replaces every editable field and sets `updatedAt` to `now`.
    /// Validates before assigning anything: on throw, no field changes.
    func update(
        productName: String,
        vendor: String,
        registeredEmail: String,
        purchaseDate: Date?,
        version: String,
        notes: String,
        now: Date = .now
    ) throws
}
```

Design choices and the requirement each one serves:

- **Field set (R1, R2).** Exactly the nine stored properties of `LicenseSummary`, same names
  and types, nothing else. No property, computed or stored, refers to a serial or key.
- **Validation (R3, D2).** One private static check,
  `productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, the same rule as
  `LicenseDraft.hasValidProductName`. It is used by `init` and `update`. The trimmed value
  is only tested, never stored (R5).
- **No bypass (R4).** Every stored property is `private(set)`. The only write paths in the
  model's own API are the throwing `init` and the throwing `update`. Making all fields
  `private(set)`, not only `productName`, also keeps R8 true for ordinary code: no caller
  can assign a field without `updatedAt` moving. `private(set)` does not close the
  SwiftData reflective API, see "R4 residue" below.
- **Full-replacement update.** `update` takes every editable field, matching
  `LicenseRepository.update(id:with:)`, which receives a complete `LicenseDraft`. This avoids
  `Date??` parameters for "leave `purchaseDate` alone" versus "clear it". The model does not
  take a `LicenseDraft`, because the draft carries the serial (R2) and `normalized` trims
  values (R5). Mapping draft to model stays in #4.
- **Failed update (R9).** `update` validates first and returns by throwing before any
  assignment, so the entity, `updatedAt` included, is untouched.
- **Identity (R6).** `id` defaults to `UUID()` and accepts a caller value. It is
  `private(set)` and no method assigns it after `init`.
- **Timestamps (R8, R10).** Time is passed in, no clock protocol: `createdAt` and `now`
  default to `.now`, tests always pass fixed dates. `updatedAt: nil` means "same as
  `createdAt`", so a default creation has `createdAt == updatedAt`. The model does not check
  that `updatedAt >= createdAt` on import: the SPEC does not ask for it.
- **Uniqueness (R7).** `@Attribute(.unique)` on `id`. See the next section.

Prototype check (2026-11-19, `xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`,
Xcode 27.2): a `@Model` class with a throwing `init`, `private(set)` stored properties,
`@Attribute(.unique) private(set) var id: UUID` and a `#Predicate { $0.id == u }` fetch
compiles and runs without warnings.

## R4 residue: SwiftData's reflective write API

**Finding (confirmed).** `PersistentModel` has a public protocol extension with
`setValue(forKey: KeyPath<Self, Value>, to:)` and a public requirement
`persistentBackingData { get set }`, whose `BackingData` also has
`setValue(forKey:to:)` (SwiftData.swiftinterface, MacOSX27.2.sdk, lines 621, 637, 1410).
Both take a read-only `KeyPath`, which `private(set)` still lets any file in the module form.

Prototype (2026-11-19, `xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`, run on
macOS 27.2.1, in-memory store; model and caller in separate files):

| Call from another file | Compiles | Effect |
|------------------------|----------|--------|
| `license.setValue(forKey: \.productName, to: "")` | yes | name becomes `""` |
| `license.persistentBackingData.setValue(forKey: \.productName, to: "   ")` | yes | name becomes `"   "`, and `save()` persists it |
| `License(backingData: License.createBackingData())`, insert, `save()` | yes | process crashes at `save()` ("Could not cast value of type Optional<Any> to UUID") |

So R4 as written ("no write path to `productName` that skips the R3 check") is not met by
`private(set)` alone.

**Mechanisms considered.**

- **Shadow `setValue` in `License`.** Not viable. The setters the `@Model` macro generates
  call `self.setValue(forKey: \.productName, to:)` (seen with `-dump-macro-expansions`), and
  generic code over `PersistentModel` would still reach the extension.
- **M1, private stored property (rejected by the owner, D3).** Persist the name as `private var storedProductName:
  String` and expose `var productName: String { storedProductName }`. A key path to a
  `private` property cannot be formed outside the file (prototype: "'secretName' is
  inaccessible due to 'private' protection level"), so the two `setValue` routes are
  closed for the name. Costs: the schema attribute is called `storedProductName`, not
  `productName`, which departs from R1 as literally written ("stored fields ... productName");
  `#Predicate` and `SortDescriptor` cannot use the computed `productName`, so #4 and #5 can
  only sort and filter by name through static descriptors defined inside `License.swift`
  (for example `License.sortByName`); and it covers `productName` only, the other fields
  stay reachable through `setValue`. It still does not close replacing
  `persistentBackingData` wholesale or `init(backingData:)`.
- **M2, documented residue (chosen by the owner, D3, SPEC v1.2 R4).** Keep `private(set)` on every stored property, accept that the
  SwiftData reflective API is an escape hatch no access modifier closes, and enforce it by a
  source check: no file other than `Sources/Model/License.swift` may call it.

**No mechanism closes every path.** `init(backingData:)` and the settable
`persistentBackingData` are `PersistentModel` requirements that the macro must provide, so
in-module code can always reach them.

**Decision: M2 (D3).** The remaining paths need deliberate use of SwiftData plumbing that
the app has no reason to touch. M1 would change the schema naming fixed by R1 and make every
name query in #4 and #5 go through `License.swift`, while still leaving the backing-data
paths open.

**Check that enforces M2** (Reviewer in T2 and at every later code review per SPEC v1.2 R4;
a candidate for the CI in #12). It is a superset of the SPEC's two patterns:

```bash
grep -rnE 'setValue\(forKey|setTransformableValue|persistentBackingData|backingData:|createBackingData' \
  Sources Tests --include='*.swift' | grep -v '^Sources/Model/License.swift:'
```

Expected output: empty. `Sources/Model/License.swift` itself should not contain these calls
either; the macro expansion is not in the source file, so the grep does not see it.

## R7: how SwiftData enforces `id` uniqueness

**Mechanism available on macOS 14.** `Schema.Attribute.Option.unique`, used as
`@Attribute(.unique)`, is annotated `@available(macOS 14, ...)` in the SDK interface
(`SwiftData.swiftmodule/arm64e-apple-macos.swiftinterface`, MacOSX27.2.sdk). The
compound-constraint macro `#Unique` is `@available(macOS 15, ...)`, so it is not usable on
the macOS 14 baseline.

**Behaviour on a duplicate insert: upsert, no error.** Apple, WWDC23 session 10195 "Model
your schema with SwiftData" (transcript read on 2026-11-19): "If a trip already exists with
that name, then the persistent back end will update to the latest values. This is called an
upsert. An upsert starts as an insert. If the insert collides with existing data, it becomes
an update and updates the properties of the existing data." The API reference page for
`unique` returned no body text when fetched, so the WWDC transcript is the only Apple
source found.

**Local experiment (2026-11-19, macOS 27.2.1 runtime, in-memory store).**

1. Insert id U "Example App", save. Insert a new object with id U "Other App", save.
   The second `save()` does not throw. A fresh `ModelContext` fetches one entity with the
   values of the second insert: the first entry's data, `createdAt` included, is overwritten.
2. Two objects with the same id V inserted before one `save()`: no throw, one entity
   remains, and it holds the values of the first insert.

Limits: the experiment ran on the macOS 27.2 runtime, not on macOS 14, and no macOS 14
machine is available. Run 1 and run 2 disagree on which values win, so the winner must not
be part of any test.

**What R7 guarantees, then.** The store never holds two entities with the same `id`. It
does not reject a duplicate: it merges silently.

### A8 (uniqueness), accepted into SPEC v1.1

Insert a `License` with id U and save. Insert a second `License` with the same id U and
different values, and save. `save()` does not throw. A fetch by id U in a new
`ModelContext` on the same container returns exactly one entity, and the total count is 1.
The test does not assert which values survive.

The "`save()` does not throw" part is the most OS-dependent assertion: it was observed on
macOS 27.2 only, and the CI (#12) may use another macOS image. If it fails on another host,
that is a finding to report, not a test to loosen silently.

### Consequence for later tickets (closed)

Because a duplicate insert overwrites an existing entry without an error, the repository
(#4) and import (#10, `ConflictPolicy.skip` / `.replace`) must fetch by id before inserting.
The owner approved this on 2026-11-19 and the Lead added the requirement to #4 and #10.

## Tickets

### T1. SwiftData `License` model with tests

- Owner: backend
- Depends on: SPEC v1.2 (done). No dependency on #3 or #8.
- Parallelism: none needed inside #2 (2 points, one owner). It runs in parallel with #3 and
  #8 in their own worktrees: new files only, so no merge conflict is expected.
- Work:
  1. Create `Sources/Model/License.swift` as in "Model design". It must not call the
     reflective API listed in "R4 residue" either.
  2. Create `Tests/LicenseModelTests.swift`, `@MainActor` suite. Each test builds its own
     container and keeps it in a local `let container` for the whole test (not only its
     `mainContext`, or the store can be released mid-test): `ModelContainer(for:
     License.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`. Writes
     go through `container.mainContext`; reads go through a new `ModelContext(container)`
     only after `save()`, so the check hits the store and not the in-memory object graph.
     A read from a new context without a prior `save()` proves nothing, because the store
     has not changed.
  3. Fixed dates only, for example `T = Date(timeIntervalSinceReferenceDate: 800_000_000)`,
     `T+1 = T.addingTimeInterval(60)`. No `sleep`, no comparison with `Date()`.
  4. Fake data only: "Example App", "Acme Corp", "Other App", "user@example.com".
  5. `tuist generate --no-open`, then the `build` and `test` commands in `CLAUDE.md`.
- Expected outcome: two new files, build and all tests green, including the existing suites.
- Tests to write (one `@Test` each, A8 as defined above):

| Test | SPEC | Asserts |
|------|------|---------|
| createStoresDefaults | A1, R1, R6, R8 | values, `""` defaults, `purchaseDate == nil`, `createdAt == updatedAt == T` |
| createKeepsSuppliedIdentityAndDates | A2, R6, R8 | id U, `createdAt` T0, and `updatedAt` when also supplied |
| createRejectsBlankName (`""`, `"   "`, `"\n\t"`) | A3, R3 | throws `.emptyProductName`, count stays 0 after `save()` |
| createKeepsNameUntrimmed | A6, R5 | `" Example App "` stored as given |
| updateChangesFieldsAndBumpsUpdatedAt | A4, R6, R8 | `version == "2.0"`, `updatedAt == T+1`, `createdAt == T`, same id |
| updateRejectsBlankNameAndKeepsState | A5, R3, R9 | create, save, snapshot all nine fields; call `update` with `"  "` and other changed values; it throws `.emptyProductName`; then (1) every field of the same instance equals the snapshot, (2) `mainContext.save()`, (3) a new-context fetch by id equals the snapshot |
| updateCanClearOptionalFields | R3 | `""` and `purchaseDate: nil` accepted on update |
| deleteRemovesEntity | A7 | fetch by id empty, count drops by one |
| duplicateIdKeepsOneEntity | A8, R7 | no throw, one entity for U, total count 1 |

- Verification: Reviewer checks T1 against R1, R2, R4 (source inspection) and the table above;
  QA runs R12.

### T2. Review and QA of the combined result

- Owner: Reviewer (code-reviewer), then QA. Both read-only.
- Depends on: T1.
- Reviewer checks:
  - R1, R2: field list and types against `LicenseSummary` in
    `Sources/Contract/LicenseContract.swift`; no serial-related property or comment that
    implies one.
  - R4: every stored property is `private(set)`; the only mutators are the throwing `init` and
    `update`; no `@Transient` or extension adds a setter; the grep in "R4 residue" prints
    nothing.
  - R5: the trimmed name is never assigned.
  - R11: tests use only in-memory containers, each kept in a local `let`, and fake values.
  - Scope, on the committed branch: `git status --short` shows no untracked or modified file
    under `Sources/` or `Tests/`, and `git diff --stat 61dd579 HEAD` lists only
    `Sources/Model/License.swift`, `Tests/LicenseModelTests.swift` and, per O2, the files
    under `docs/specs/`.
- QA checks (R12): `tuist generate --no-open`, then
  `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -destination
  'platform=macOS' build` and `... test`. All suites pass, not only the new one. Note the
  macOS version of the test host in the report (R7 behaviour was observed on 27.2 only).

## Requirement coverage

| Req | Where | Verified by |
|-----|-------|-------------|
| R1 | model fields | Reviewer (T2) |
| R2 | model fields | Reviewer (T2) |
| R3 | `init`, `update` validation | A3, A5 tests |
| R4 | `private(set)` on every stored property, documented residue (D3) | Reviewer (T2), grep check |
| R5 | validation does not assign trimmed value | A6 test, Reviewer |
| R6 | `id` default and parameter, `private(set)` | A1, A2, A4 tests |
| R7 | `@Attribute(.unique)` | this note, A8 test |
| R8 | `createdAt`, `updatedAt`, `now` parameters | A1, A2, A4 tests |
| R9 | validate before assign in `update` | A5 test |
| R10 | dates passed in | all tests use fixed dates |
| R11 | `Tests/LicenseModelTests.swift` | Reviewer, QA |
| R12 | build and test | QA (T2) |

## Open points for the Lead

- Q1 (closed): A8 accepted as proposed, written into SPEC v1.1.
- Q2 (closed): owner approved; the Lead added fetch-before-insert to #4 and #10.
- Q3 (closed): owner chose M2 (D3), written into SPEC v1.2 R4.
- O1, O2 from the SPEC (who commits, whether `docs/specs/` stays) are unchanged. This plan
  file sits next to the SPEC and falls under O2.
