# Plan: License repository that keeps entry and serial consistent (ticket #4)

- Plan version: v1.1 (v1 got CHANGES REQUESTED at PLAN review on 2026-11-20; v1.1 folds in B1 to B4 and
  S1 to S8, and records Stefano's D9 and D10; re-review APPROVED v1.1 at sha256 c1bedd9288c8, whose
  non-blocking S9 to S11 are folded in here with P11)
- Date: 2026-11-20
- Input: `docs/specs/0004-license-repository.md` v1.1 (approved by Stefano on 2026-11-20), `docs/adr/0001-storage.md`,
  `docs/design/gui.md` ("Contract with the data layer"), `docs/specs/license-model-plan.md` ("R7"),
  baseline `b8d6e14` (= `origin/main`)
- Author: Architect
- Status: v1.1, PLAN re-review APPROVED (2026-11-20); later edits are wording, S9 to S11 and P11

## 1. Findings that shape the plan

Prototypes ran on 2026-11-20 on macOS 27.2.1 with Xcode 27.2, compiled with
`xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`. No macOS 14 host is available and CI runs
macOS 26 with Xcode 26.6, so every behaviour below is observed on 27.2 only.

- **P1. `@ModelActor` with a custom init compiles under Swift 6.** An actor annotated `@ModelActor` that
  defines `init(container:hook:)` and sets `modelContainer` and `modelExecutor =
  DefaultSerialModelExecutor(modelContext: ModelContext(container))` itself compiles without warnings and
  runs. `ModelActor`, `DefaultSerialModelExecutor` and `ModelContext.rollback()` are `@available(macOS 14)`
  in the SDK interface (`SwiftData.swiftmodule/arm64e-apple-macos.swiftinterface`, MacOSX27.2.sdk).
- **P2. `rollback()` restores the context in all three cases.** On an in-memory container, inside the actor:
  insert then `rollback()` leaves `fetchCount == 0` and `hasChanges == false`; mutate a fetched object then
  `rollback()` gives back the old value both on the object and on a re-fetch; `delete` then `rollback()`
  brings the object back (`isDeleted == false`) and a later `save()` keeps it in the store.
- **P3. A real SwiftData save failure can be forced**, but not in memory. `ModelConfiguration(isStoredInMemoryOnly:
  true, allowsSave: false)` fails at container creation. An on-disk store in a temporary directory, seeded by a
  writable container and reopened with `allowsSave: false`, makes `save()` throw `NSCocoaErrorDomain` 513.
  The plan does not use it (see O2).
- **P4. The default store is shared.** For this non-sandboxed app, `ModelConfiguration().url` is
  `~/Library/Application Support/default.store`, the same path every other non-sandboxed SwiftData app
  uses by default. The app needs its own URL (T2).
- **P5. A `LocalizedError` that returns nil keeps the generic text.** For an enum conforming to
  `LocalizedError` whose `errorDescription` is nil for a case, `localizedDescription` is
  "The operation couldn't be completed. (<Module>.<Type> error N.)", the same text as a plain `Error`.
  The case returning a string gets that string.
- **P6. Five catch sites show repository errors**, not two: `LicenseStore.swift` lines 61 (load) and 93
  (serial read), `LicenseFormModel.swift` lines 68 (save) and 82 (delete), `ContentView.swift` line 154
  (delete from the detail toolbar). All five use `error.localizedDescription`.
- **P7. The Release branch of `SerialManagerApp.init()` is never compiled by CI**, which runs
  `xcodebuild test` in Debug.
- **P8. The main window already has a failure state**: `ContentView` shows "Couldn't Load Licenses", the
  message and a Try Again button when `store.phase` is `.failed`.
- **P9. Two mutations on one id can overlap.** `ContentView` guards New and Edit with `formRequest == nil`,
  but not Delete: the "Delete License…" menu command sets `pendingDelete` while the edit sheet is open
  (`ContentView.swift` line 84; `gui.md` "Known gaps" says menu commands stay enabled under a sheet).
- **P10. A FIFO mutation lock inside the actor works and compiles under Swift 6.** An actor-isolated
  `acquire()` / `release()` pair (a `busy` flag plus an array of `CheckedContinuation<Void, Never>`, ownership
  handed to the first waiter on release) used as `await acquire(); defer { release() }` serialises two calls
  that both suspend: with call A suspended inside the lock and call B's own gate already open, B does not
  start until A ends (log `A start, A end, B start, B end`). A variant wrapping the body in a `Task`
  closure was rejected by the Swift 6 region checker (`SendingClosureRisksDataRace`), so the plan uses the
  continuation form. The same prototype shows the test technique: a store call that suspends on a gate
  until the test releases it.

- **P11. The macro form of P1 does not combine with the lock; explicit conformance does.** With
  `@ModelActor` on an actor that also has a `let` without a default value (here `beforeSave`), the macro's
  generated `init(modelContainer:)` fails to compile ("return from initializer without initializing all
  stored properties"). Declaring `actor Repo: ModelActor` by hand, with `nonisolated let modelContainer`
  and `nonisolated let modelExecutor: any ModelExecutor` set in the custom init (context with
  `autosaveEnabled = false`), compiles under Swift 6 with the P10 lock inside, and the run keeps the order:
  a second call is observed suspended in `acquire()` (waiter count 1) while the first holds the lock, then
  `A start, A end, B start, B end`, two entities stored. This answers S10.

## 2. Design

### 2.1 Types (all in the app target)

| Type | File | Owner |
| --- | --- | --- |
| `actor SwiftDataLicenseRepository: LicenseRepository, ModelActor` (explicit conformance, P11) | `Sources/Data/SwiftDataLicenseRepository.swift` | Backend |
| `enum LicenseRepositoryError: Error, Equatable { case notFound(UUID), duplicateID(UUID), libraryUnavailable }` | same file | Backend |
| `enum LicenseLibrary` (store URL, container factory, repository factory) | `Sources/Data/LicenseLibrary.swift` | Backend |
| `struct UnavailableLicenseRepository: LicenseRepository` | `Sources/Support/UnavailableLicenseRepository.swift` | Backend |
| `extension SerialStoreError: LocalizedError` (D4 text) | `Sources/Store/SerialStoreError+Message.swift` | Frontend |
| `extension LicenseRepositoryError: LocalizedError` (D8 text, `.libraryUnavailable` only) | `Sources/Store/LicenseRepositoryError+Message.swift` | Frontend |
| `actor ScriptedSerialStore: SerialStore` (test double) | `Tests/Support/ScriptedSerialStore.swift` | Backend |

`Sources/Contract/LicenseContract.swift`, `Sources/Model/License.swift`, `Sources/Data/Serials/*` and
`Sources/Fakes/*` do not change.

### 2.2 Concurrency (answers the first open point)

`SwiftDataLicenseRepository` is an actor conforming to `ModelActor` explicitly (not the `@ModelActor` macro, P11): the protocol is `Sendable`, an actor is, and the
model executor keeps its `ModelContext` on one serial executor. The repository returns only
`LicenseSummary` values, never a `License`. `ModelContext` is marked `@unchecked Sendable` in the 27.2 SDK;
the design must not rely on that (CI builds with the 26.6 SDK).

Init (internal, all parameters but the first two defaulted):

```swift
init(
    modelContainer: ModelContainer,
    serials: any SerialStore,
    makeID: @escaping @Sendable () -> UUID = { UUID() },
    now: @escaping @Sendable () -> Date = { Date() },
    beforeSave: @escaping @Sendable () throws -> Void = {}
)
```

`persist()` below means: `try beforeSave()`, then `try modelContext.save()`. The hook takes no
`ModelContext`, so the seam does not depend on `ModelContext` being `Sendable` in any SDK. P1 compiled a
variant whose hook received the context; the parameterless form is strictly simpler.

**Invariant I1: no unsaved SwiftData change is held across an `await`.** Actor methods are re-entrant: while
one call awaits the serial store, another can run on the same context, and its `save()` or `rollback()`
would commit or discard the first call's pending changes. So every operation does its Keychain work first,
then mutates the context, persists and (on failure) rolls back in one synchronous stretch with no `await`
in between. Compensating Keychain calls happen only after `rollback()`, when the context is clean again.
The Reviewer checks I1 by reading each method: between `insert`/`update`/`delete` on the context and the
end of `persist()`/`rollback()` there is no `await`.

**Invariant I2: re-fetch after every `await`.** The entry is looked up again after the Keychain step,
never reused from before it, because another call may have deleted it meanwhile.

**Invariant I3: mutations run one at a time.** `KeychainSerialStore.save` documents that the consumer
serialises its operations per license, and P9 shows the GUI can start a delete while an update of the same
entry is in flight. I1 and I2 alone do not prevent an orphan in that case: delete removes the serial, update
reads "absent" and saves a new one, delete then removes the entry, and every call succeeds. So `create`,
`update` and `delete` each start with `await acquire(); defer { release() }` (P10): a FIFO lock held in the
actor, one for all ids. The review recommended per-id serialisation; a single lock for all ids gives the
same guarantee for any one id and more (no two mutations ever overlap), with less code to review: no
dictionary of waiters to clean up. Mutations are user-driven and rare, so queueing across ids costs nothing
a user can notice. `fetchAll()` and `serial(for:)` do not take the lock: by I1 the
context never holds unsaved changes across a suspension, so a read sees committed state only. The lock is
not reentrant; no mutation calls another. The code comment on the lock says that a Keychain call that never
returns blocks every later mutation (reads still work) (S11). The repository exposes an internal
`pendingMutationCount` (the number of waiters) for the I3 test only.

The init sets `modelContext.autosaveEnabled = false` explicitly, so nothing but `persist()` ever saves the
context and `rollback()` always sees the pending change (the default for a context created this way is not
verified).

Context thread: a `ModelActor` created on the main thread (Release `init()` of the app) may end up running
its context on the main queue; that would cost responsiveness only, not correctness. T2 checks it once
(`Thread.isMainThread` inside a repository call, Debug log only, removed before commit).

### 2.3 Operations

Notation: `old` is the result of reading the serial before a change, one of three states:
**absent** (no item), **value(v)**, **unreadable** (the read threw `.undecodableData`, see 2.4). The
implementation models them explicitly (for example a private `enum PreviousSerial`), never by folding
unreadable into nil.

**`fetchAll()`** (R11): fetch every `License`, map to `LicenseSummary`. Never calls the serial store.

**`serial(for:)`** (R11, D6): `try await serials.serial(for: id)`, unchanged. Nil for a missing item;
the serial store's errors pass through as they are.

All three mutations start with `await acquire(); defer { release() }` (I3).

**`create(_ draft:)`** (R1 to R5, R12):
1. `id = makeID()`, `date = now()`.
2. `license = try License(id: id, ..., createdAt: date)`. A blank name throws
   `LicenseValidationError.emptyProductName` here, before any write (R5).
3. Fetch `id`. If an entry exists, throw `LicenseRepositoryError.duplicateID(id)` (R4, D5). Nothing was
   written, so the existing entry and its serial are untouched.
4. If `draft.serial` is not empty, `try await serials.save(draft.serial, for: id)`. On failure, rethrow:
   nothing is in the context (R3, first half). An empty serial writes nothing (R2, D7).
5. Synchronously: `insert(license)`, `try persist()`. On failure: `rollback()`, then, if a
   serial was saved in step 4, `try? await serials.deleteSerial(for: id)`, then rethrow the persist error
   (R3, second half; R12 if the delete fails: an orphan serial may remain).
6. Return the summary of `license` (`createdAt == updatedAt`).

The single duplicate check in step 3 is enough (S3, moot under I3): there is an `await` between it and the
insert, but I3 keeps any other mutation out of that window, ids come from `makeID` (`UUID()` outside tests), and the check runs
before the only Keychain write. The code says so in a comment. Import with a caller-supplied id is #10.

**`update(id:with:)`** (R5 to R8, R12):
1. If `!draft.hasValidProductName`, throw `LicenseValidationError.emptyProductName` (R5). It is the same
   rule as `License.validate`, so `License.update` cannot throw later for this reason.
2. Fetch `id`. If missing, throw `LicenseRepositoryError.notFound(id)` (R7). Nothing written.
3. Read `old` (2.4 for a failing read).
4. Serial step:

   | `old` | `draft.serial` empty | `draft.serial` = s |
   | --- | --- | --- |
   | absent | nothing | `save(s)` |
   | value(v) | `deleteSerial` | nothing if v == s, else `save(s)` |
   | unreadable | `deleteSerial` | `save(s)` |

   On failure, rethrow: the context was never touched, so the fields and `updatedAt` are the previous ones
   (R8, first half; A6).
5. Synchronously: re-fetch `id` (I2; with I3 the entry cannot vanish, the branch is defensive).
   - Gone: `try? await serials.deleteSerial(for: id)` if step 4 wrote, so no orphan is left, then throw
     `notFound(id)`.
   - Present: `try license.update(..., now: now())` and `try persist()` inside one `do`. Any error from
     either (S4: `update` cannot throw after step 1, but its failure takes the same path) leads to:
     `rollback()`, then, if step 4 wrote, compensate with `try?`: absent → `deleteSerial`; value(v) →
     `save(v)`; unreadable → nothing, the new state stays (2.4). Then rethrow the original error (R8,
     second half; R12).
6. Return the summary (R6: `id` and `createdAt` kept, `updatedAt` = `now()`).

**`delete(id:)`** (D1, R9, R10, R12):
1. Read `old` (2.4 for a failing read).
2. `try await serials.deleteSerial(for: id)`. On failure, rethrow: the entry is not touched (D1, A7). This
   runs for an unknown id too (R10).
3. Synchronously: fetch `id`. Missing: return (R10). Present: `delete(license)`, `try persist()`.
   On failure: `rollback()`, then compensate with `try?`: absent → nothing; value(v) → `save(v)`;
   unreadable → nothing, the item stays deleted (2.4). Then rethrow (R9, second half; R12).

**Errors are never wrapped.** The repository rethrows the serial store's and SwiftData's errors as they
are, so `SerialStoreError.accessDenied` reaches the GUI catch sites unchanged and the D4 conformance
applies. Compensation errors are discarded (`try?`); the original error is thrown (R12, D3). Each `try?` on
a compensation carries a comment naming the residue (orphan serial, stale serial).

### 2.4 O1: the read before a change fails (decided: D9)

Restoring "the previous serial" (R8, R9) means reading it first, and that read can fail. For update and
delete alike:

- `.accessDenied` or `.unexpected`: the operation throws that error before writing anything. The write
  that follows would hit the same Keychain anyway; D1 and D2 hold.
- `.undecodableData`: the stored value is unusable, and blocking would leave the user unable to fix or
  delete that entry. The operation proceeds with `old` treated as "not restorable": if the SwiftData step
  then fails, the serial is not restored (delete) or keeps the new value (update). This is a failed
  rollback in the sense of D3: the original error is thrown and the case is documented in code (D9, R12).

### 2.5 Test seams (answers the second open point)

- **Id source**: `makeID`. A4 passes a closure that returns U, so a second `create` collides with the
  entry created first.
- **Clock**: `now`. Tests use fixed dates (`t`, `t + 60`), as `LicenseModelTests` does, to tell `createdAt`
  from `updatedAt` and to check "old `updatedAt`" in A6.
- **Forced save failure (O2)**: `beforeSave`. Tests build one repository with the default hook to seed
  data, then a second repository on the same in-memory container with `beforeSave: { throw TestError() }`.
  This keeps R15's in-memory container. What it does not exercise: a real SwiftData failure inside `save()`.
  The context state at that point is the same pending change, and P2 shows `rollback()` clears it; P3 shows a
  real failure is possible with an on-disk read-only store, kept out of the suite because R15 asks for
  in-memory containers and the `allowsSave` behaviour is observed on 27.2 only.
- **Serial store double (third open point)**: a new `ScriptedSerialStore` in `Tests/Support/`.
  `InMemorySerialStore` fails every operation at once and is shared with previews, and the SPEC keeps the
  fakes' behaviour out of scope, so it stays as it is. `ScriptedSerialStore` has:
  - a dictionary of items, seedable in `init`;
  - an independent failure per operation (`read`, `save`, `delete`), each with a number of calls to let
    through first, so a test can let step 4 succeed and fail the compensation (R12);
  - a call log of `(operation, id)` to assert "no read" (R11), "delete called for an unknown id" (R10) and
    "no write" (R4, R5, R7);
  - an optional gate per operation: the call suspends until the test opens it (P10), to hold one mutation
    inside the lock while a second one is started (I3 test).

### 2.6 D4 and D10: where the messages live (fourth and fifth open points)

`extension SerialStoreError: LocalizedError` in a Frontend-owned file, `Sources/Store/SerialStoreError+Message.swift`:
`errorDescription` returns `String(localized: ...)` for `.accessDenied` and nil for every other case. With
P5, the other cases keep today's generic text, and all five catch sites of P6 show the dedicated text without
being edited, including the ones reached by create, update and delete (A3 surfaces through
`LicenseFormModel` line 68). The conformance lives in the app module next to the GUI code; the type stays in
`Sources/Data/Serials/SerialStore.swift`, untouched. It only works because the repository never wraps errors
(2.3), which T1's tests assert with `#expect(throws: SerialStoreError.accessDenied)`.

Proposed text (Frontend's call): "Keychain access was denied. Try again, or check the Keychain permissions
for SerialManager." It goes into `Resources/Localizable.xcstrings`, like the other strings.

### 2.7 Wiring and the store (R14, D8)

`LicenseLibrary` (Backend), compiled in every configuration so Debug tests cover it (P7):

- `static let folderName = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"`, its own constant,
  not coupled to `KeychainSerialStore.defaultService` (S7).
- `static var defaultStoreURL: URL`: `Application Support/<folderName>/Licenses.store` (P4).
- `static func makeContainer(at url: URL) throws -> ModelContainer`: creates the parent directory, then
  `ModelContainer(for: License.self, configurations: ModelConfiguration(url: url))`.
- `static func makeRepository(at url: URL = defaultStoreURL, serials: any SerialStore = KeychainSerialStore()) -> any LicenseRepository`:
  returns `SwiftDataLicenseRepository` on success, `UnavailableLicenseRepository` when `makeContainer` throws.

`SerialManagerApp.init()`, Release branch only: `let repository = LicenseLibrary.makeRepository()`. Debug
and previews keep `InMemoryLicenseRepository`. The comment at the top of the type is updated.

D8: `UnavailableLicenseRepository` throws `LicenseRepositoryError.libraryUnavailable` from every method.
`LicenseStore.load()` then shows the existing failure state (P8): "Couldn't Load Licenses", the message,
Try Again. Create, update and delete fail with the same message, so nothing typed is accepted and lost. No
in-memory fallback. D10: the message is dedicated, proposed in R13 ("SerialManager couldn't open its library
file. Quit and reopen the app; if this keeps happening, check the disk."). It is an
`extension LicenseRepositoryError: LocalizedError` owned by Frontend (T3), returning the text for
`.libraryUnavailable` and nil for `notFound` and `duplicateID`, so all strings and the catalog stay with one
owner. Try Again cannot succeed here, because the repository is fixed at launch: the text says to quit and
reopen, and a working Try Again is a GUI follow-up (section 6).

QA forces the failure on a Release build: quit the app, rename
`~/Library/Application Support/it.stefer.SerialManager` to a backup name and create an empty regular file
with that name, launch, see the failure state; then delete the file and rename the folder back.

## 3. Tickets

### T1. Repository, error type and unit tests

- Owner: Backend.
- Files: `Sources/Data/SwiftDataLicenseRepository.swift` (new), `Tests/Support/ScriptedSerialStore.swift`
  (new), `Tests/SwiftDataLicenseRepositoryTests.swift` (new).
- Depends on: nothing. Parallel with T3.
- Requirements: R1 to R12, R15 (repository side), D1, D2, D3, D5, D6, D7, D9, I1, I2, I3, O1.
- Expected outcome: section 2.3 implemented; compensations documented in code; every test below green.
- Tests (in-memory container held in a local `let`, reads through a new `ModelContext(container)`, fake
  values only, fixed dates):

| Test | Covers | Asserts |
| --- | --- | --- |
| `createStoresEntryAndSerial` | A1, R1 | one entry "Example App", item `ACME-0000-TEST-0000` under its id, `createdAt == updatedAt == t` |
| `createWithEmptySerialWritesNoItem` | A2, R2, D7 | one entry, zero items, no `save` in the log, `serial(for:)` nil |
| `createSerialFailureLeavesNothing` | A3, R3 | throws `SerialStoreError.accessDenied` unwrapped, zero entries, zero items |
| `createPersistFailureDeletesSerial` | R3 | throws the persist error, zero entries in a new context and in the repository's own `fetchAll()`, zero items |
| `createDuplicateIDChangesNothing` | A4, R4, D5 | throws `duplicateID(U)`, U still "Example App" with its `createdAt`, serial still S, no `save` for the second call |
| `createAndUpdateRejectBlankName` | R5 | `emptyProductName`, no write in the log, store unchanged |
| `updateReplacesFieldsAndSerial` | R6 | new fields, `updatedAt == t+60`, same `id` and `createdAt`, item S2 |
| `updateWithEmptySerialDeletesItem` | A5, R6, D6 | item gone, entry kept, `updatedAt` changed, `createdAt` not |
| `updateUnknownIDThrowsNotFound` | R7 | `notFound(id)`, no write in the log |
| `updateSerialFailureKeepsEntry` | A6, R8 | throws, U "Example App" with the old `updatedAt`, serial S |
| `updatePersistFailureRestoresSerial` | R8 | throws the persist error, old fields in a new context and in `fetchAll()`, serial S; second case with no previous serial: item deleted again |
| `updateReadDeniedWritesNothing` | O1 | `accessDenied` on the read, no write, entry unchanged |
| `deleteRemovesBoth` | A7, R9, D1 | zero entries, zero items |
| `deleteSerialFailureKeepsEntry` | A7, R9, D1 | throws, U still fetched, serial S |
| `deletePersistFailureRestoresSerial` | R9 | throws the persist error, U still in a new context and in `fetchAll()`, serial S |
| `deleteUnknownIDStillDeletesSerial` | R10 | no throw, one `delete` for that id in the log |
| `fetchAllReturnsEntryWithoutSerial` | A8, R11 | U returned, no `read` in the log; `serial(for: U)` nil |
| `serialPassesStoreErrorsThrough` | R11 | `serial(for:)` throws `.unexpected(status:)` unwrapped |
| `failedCompensationThrowsOriginalError` | R12, D3 | for create, update and delete: persist fails, compensation fails; the persist error is thrown, no crash, the residue (orphan or stale item) is asserted as documented |
| `updateDeleteSerialFailureKeepsEntry` | R8 | update with an empty serial over value S, `deleteSerial` fails: throws it unwrapped, U unchanged with the old `updatedAt`, serial S |
| `deleteReadFailureWritesNothing` | O1, D9 | read throws `.accessDenied`, then (second case) `.unexpected(status:)`: delete throws it, no `delete` in the log, U and S unchanged |
| `undecodableReadDoesNotBlock` | O1, D9 | update and delete proceed when the read throws `.undecodableData` |
| `undecodableUpdatePersistFailureKeepsNewSerial` | R12, D9 | read `.undecodableData`, `save(s)` succeeds, `beforeSave` throws: the persist error is thrown, U has its old fields, the item holds s, no compensating call in the log |
| `undecodableDeletePersistFailureLeavesItemDeleted` | R12, D9 | read `.undecodableData`, `deleteSerial` succeeds, `beforeSave` throws: the persist error is thrown, U still present, no item, no compensating `save` in the log |
| `overlappingMutationsRunInOrder` | I3, B3 | U with serial S; start `delete(U)` with its `deleteSerial` held on a gate, wait until the log shows that call, then start `update(U, serial S2)` and wait until `pendingMutationCount == 1`, so the update is proven suspended in `acquire()` before the gate opens (S9: without this wait the test can pass with no lock); open the gate: delete succeeds, update throws `notFound(U)`, zero entries, zero items, and the log shows no call of the update before delete's last call |

- Verification: Reviewer reads I1, I2 and I3 in each method, checks `autosaveEnabled = false` in the init, checks the table against R1 to R12, and checks that no
  file under `Tests/` creates `KeychainSerialStore` except `KeychainSerialStoreTests` (which injects a fake
  client). CI green.

### T2. Library factory, Release wiring, unavailable state

- Owner: Backend.
- Files: `Sources/Data/LicenseLibrary.swift` (new), `Sources/Support/UnavailableLicenseRepository.swift`
  (new), `Sources/SerialManagerApp.swift`, `Tests/LicenseLibraryTests.swift` (new).
- Depends on: T1 (the repository type and `LicenseRepositoryError`). Same agent, after T1.
- Requirements: R14, D6, D8 (behaviour; the D8 text is T3's).
- Expected outcome: section 2.7. Release uses the persistent library with `KeychainSerialStore`; Debug and
  previews unchanged.
- Tests: `makeContainerCreatesDirectory` (temporary directory URL: the parent is created and a container
  opens); `makeRepositoryFallsBackToUnavailable` (parent path is a regular file: the result is
  `UnavailableLicenseRepository`, its `fetchAll()` throws `libraryUnavailable`); `unavailableShowsFailedPhase`
  (a `LicenseStore` on it ends in `.failed(LicenseRepositoryError.libraryUnavailable.localizedDescription)`,
  so the test does not depend on the wording). Every call passes
  `serials: InMemorySerialStore()` explicitly, so the default `KeychainSerialStore()` is never created in a
  test (R15). The temporary files are removed at the end of each test. These are the only on-disk tests; they test the factory (R14), not the repository (R15).
- Also: the one-time context-thread check of 2.2, reported in the T2 hand-off, not committed.
- Verification: Reviewer reads the `#else` branch; a local Release build compiles:
  `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release -destination
  'platform=macOS' build CODE_SIGNING_ALLOWED=NO`.

### T3. User-facing error texts and GUI doc

- Owner: Frontend.
- Files: `Sources/Store/SerialStoreError+Message.swift` (new), `Sources/Store/LicenseRepositoryError+Message.swift`
  (new, D10), `Resources/Localizable.xcstrings`,
  `Tests/ErrorMessageTests.swift` (new), `docs/design/gui.md` ("Known gaps").
- Depends on: nothing for the D4 part (`SerialStoreError` exists on main), parallel with T1. The D10 part
  needs `LicenseRepositoryError` from T1's first commit (section 4 says how it reaches Frontend).
  The "Known gaps" text describes T2's behaviour as fixed in this plan.
- Requirements: R13, D4, D10; A9; the GUI half of R11 stays covered by the existing `SerialRow`
  "missing" preview and `LicenseStoreTests`.
- Expected outcome: section 2.6. `gui.md` "Known gaps": the "Release builds are an empty, non-persistent
  shell" item is replaced by the current state (Release persists entries; Import and Export stay disabled
  until #9 and #10; startup failure shows the D8 state).
- Tests: `accessDeniedHasDedicatedText`; `otherErrorsKeepGenericText` (`.undecodableData`, `.unexpected`:
  `localizedDescription` differs from the dedicated text; no exact generic string asserted);
  `serialLookupShowsDedicatedText` (`LicenseStore.serial(for:)` with
  `InMemoryLicenseRepository(failure: SerialStoreError.accessDenied)` returns `.failed(<dedicated text>)`, A9);
  `formSaveShowsDedicatedText` (`LicenseFormModel.save` with the same failing repository sets
  `errorMessage` to the dedicated text, A3 on the GUI side); `libraryUnavailableHasDedicatedText` (D10);
  `otherRepositoryErrorsKeepGenericText` (`notFound`, `duplicateID`).
- Verification: Reviewer checks no catch site was edited and both strings are in the catalog; QA reads the text in
  a preview or the app.

### T4. Review and QA of the combined result

- Owner: Reviewer (code-reviewer), then QA. Both read-only.
- Depends on: T1, T2, T3 merged on the branch.
- Reviewer: the T1 to T3 verification items; `git diff --stat b8d6e14 HEAD` lists only the "Files" of T1, T2
  and T3, plus `docs/specs/0004-license-repository.md` and this plan; no signature change in
  `LicenseContract.swift`; no real serial or personal data.
- QA:
  1. `tuist generate --no-open`, then build and test with the CI command of `docs/ci.md`
     (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=`). All suites pass. Record the host
     macOS version.
  2. Release build with the T2 command.
  3. Release build signed with team T7H24G7BFW (R14, F4): add an entry, quit, relaunch, find it with its serial.
     Then create, read, update and delete an entry with serial `ÀÉÎ-ñ-測試-🔑`, one typed with surrounding
     spaces (stored without them), one with an empty serial (no Keychain item: Keychain Access, "Local Items",
     shows none for that id). Delete removes the item.
  4. Force the D8 state with the steps in 2.7 and restore.
  5. A9: the dedicated text in a preview or the app (QA may use a Debug build with a repository failing with
     `.accessDenied` if access cannot be denied for real).

## 4. Parallelism

```
T1 (Backend) ──> T2 (Backend) ──┐
T3 (Frontend) ──────────────────┴──> T4 (Reviewer, then QA)
```

T1 and T3 touch disjoint files. T2 and T3 share no file either: `SerialManagerApp.swift` is Backend's;
every user-facing text, the catalog and `gui.md` are Frontend's. The only ordering inside T3 is the D10
conformance, which waits for T1's `LicenseRepositoryError`.

Build isolation (S1): one worktree per developer. Backend and Frontend each work on their own branch cut
from `feature/license-repository`, in their own worktree under `.worktrees/`; Git
(`engineering-git-workflow-master`) creates them and merges both into `feature/license-repository` before
T4. Frontend never builds Backend's half-written files.

How Frontend gets `LicenseRepositoryError`: T1's first commit contains only that enum (cases fixed in 2.1,
in `Sources/Data/SwiftDataLicenseRepository.swift`). Backend tells Frontend its SHA; Frontend cherry-picks
or merges that commit into its branch and builds the D10 conformance against it. The D4 part needs nothing
from T1.

## 5. Requirement coverage

| Req | Where | Verified by |
| --- | --- | --- |
| R1, R2 | `create`, steps 1 to 6 | T1 tests A1, A2 |
| R3 | `create` steps 4, 5 | T1 `createSerialFailureLeavesNothing`, `createPersistFailureDeletesSerial` |
| R4 | `create` step 3 | T1 `createDuplicateIDChangesNothing` |
| R5 | `create` step 2, `update` step 1 | T1 `createAndUpdateRejectBlankName` |
| R6 | `update` | T1 `updateReplacesFieldsAndSerial`, `updateWithEmptySerialDeletesItem` |
| R7 | `update` step 2 | T1 `updateUnknownIDThrowsNotFound` |
| R8 | `update` steps 4, 5 | T1 `updateSerialFailureKeepsEntry`, `updateDeleteSerialFailureKeepsEntry`, `updatePersistFailureRestoresSerial` |
| R9 | `delete` | T1 `deleteRemovesBoth`, `deleteSerialFailureKeepsEntry`, `deletePersistFailureRestoresSerial`, `deleteReadFailureWritesNothing` |
| R10 | `delete` step 2 | T1 `deleteUnknownIDStillDeletesSerial` |
| R11 | `fetchAll`, `serial(for:)` | T1 two tests; existing `SerialRow` preview and `LicenseStoreTests` |
| R12 | `try?` compensations, D9 | T1 `failedCompensationThrowsOriginalError`, the two `undecodable…PersistFailure…` tests; Reviewer reads the residue comments |
| R13 | `SerialStoreError+Message.swift`, `LicenseRepositoryError+Message.swift` | T3 tests; QA steps 4 and 5 |
| I3 | the mutation lock | T1 `overlappingMutationsRunInOrder` |
| R14 | `LicenseLibrary`, `SerialManagerApp.init()` | T2 tests; Release build; QA steps 2 to 4 |
| R15 | all tests | CI green; Reviewer grep for `KeychainSerialStore(` in `Tests/` |

## 6. Open points for the Lead

- Q1 and Q2 of v1 are closed by D9 and D10 (SPEC v1.1). No open question remains for this plan.
- **QA risk (S5)**: `rollback()` (P2), the `beforeSave` seam, the lock (P10) and the upsert behaviour were
  observed on macOS 27.2 only; the deployment target is macOS 14 and CI runs macOS 26. QA records the host
  version; a regression on another OS is a finding to report, not a test to loosen.
- **Follow-up, not in this ticket**: the "Delete License…" command is not disabled while the form sheet is
  open (P9). The repository serialises the overlap (I3); disabling it is a small GUI ticket.
- **Follow-up, not in this ticket**: Try Again on the D8 failure state cannot recover, since the repository is
  chosen at launch (S6). A retry that reopens the library is a GUI and wiring ticket.
- **Follow-up, not in this ticket**: CI builds Debug only (P7). A Release build step in
  `.github/workflows/ci.yml` would catch a broken `#else` branch; it is a CI change for its own ticket.
- `PROJECT_BRIEF.md` "Status" is updated at merge by whoever closes the milestone, not by T1 to T3.
