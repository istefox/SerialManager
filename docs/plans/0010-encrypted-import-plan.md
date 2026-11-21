# Plan: Import of the encrypted backup (backlog #10)

- Plan version: v4
- Date: 2026-11-21
- Input: `docs/specs/0010-encrypted-import.md` v2 (confirmed by Stefano on 2026-11-21, sha256
  4253c215…09b7; revises D5, adds D7 and R17),
  `docs/adr/0002-backup-format.md` (normative, unchanged by this plan), `docs/adr/0001-storage.md`,
  `docs/specs/license-model.md` v1.3 (confirmed by Stefano on 2026-11-21),
  `docs/specs/license-model-plan.md` ("R7"), `docs/plans/0004-license-repository-plan.md` (I1 to I3),
  `docs/plans/0009-encrypted-export-plan.md`, `docs/design/gui.md`, baseline `4efff0c` (= `origin/main`,
  includes PR #14)
- Author: Architect
- Status: v4, waiting for PLAN review
- Changes v3 -> v4 (PLAN review round 3, CHANGES REQUESTED): `onDisappear` moves from the root `Group`
  (a modifier on a `Group` applies to each child, so the Checking -> Conflicts swap fired it and dropped
  the payload) to a stable container that replaces the `Group` (2.8, T4); T4 adds the walk password ->
  checking -> conflicts -> importing with zero `cancelImport()` calls (model test and Debug-app QA step);
  `unlock()` cancels again when the model was closed while `prepareImport` ran (A17 count in the Checking
  case, 6.5); the `.conflicts` preview prepares the fake first; SPEC v2 confirmed.
- Changes v2 -> v3 (SPEC v2, D5 revised): `BackupService.cancelImport()` (2.2, 2.7, 2.8); new ticket T0
  (backend) owns the contract change and every conformer and lands first; T4 depends on T0 only, still
  parallel with T1 to T3; the reader runs in a detached task so a cancel can interleave with a running
  `prepareImport` (F16), with a generation counter for R17; `ImportModel.close()` from the sheet's
  `onDisappear`; A15 to A17 and R17 in tickets and coverage; R12 writes now cite D7 of SPEC v2; Input
  cites SPEC v2.
- Changes v1 -> v2 (PLAN review #10, CHANGES REQUESTED): T4 test throws a local test-only error, so T4
  compiles without T2; the `deleteSerial` rule reads "only as compensation of an item this same call
  created" in 2.3, T1 and section 7, with a new T1 test (replace over no item); the T2 and T4 message
  tests build the expectation from `String(localized:)` or the thrown error, never an English literal;
  baseline moved to `4efff0c` with #14 merged (F1, F2, sections 4 to 6, T3); R12 for writes recorded as an
  accepted deviation pending owner sign-off (2.7); reader step 4 reads at most `maxBackupFileSize + 1`
  bytes; orphan serial under a new license with a null serial listed in `gui.md` Known gaps (T4); P2
  kept, SPEC wording aligned by the Lead; 6.1 and 6.2 closed.

## 1. Findings that shape the plan

Prototypes ran on 2026-11-21 on macOS 27.2 with the local toolchain, compiled with
`xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`. CI runs Xcode 26.6 on macOS 26: every
behaviour below is observed locally only, and the implementation must be green on CI.

- **F1. Baseline `4efff0c`.** `feature/encrypted-import` was fast-forwarded to `origin/main` `4efff0c`,
  which holds `a1e0553` (GitHub PR #8, backlog #13: CI builds Release) and PR #14. Since #8, CI compiles
  the `#if !DEBUG` wiring of `SerialManagerApp.init`, so R14's code side is checked by CI, not by a
  local Release build.
- **F2. PR #14 is merged** (backlog #14, in `4efff0c`): `EncryptedBackupService.init` takes `deriveKey`
  and `seal` closures (tests only), and `BackupFixtures.service` takes a `stageProbe`. This plan reuses
  the `deriveKey` closure as the probe for "no key derived" (A5) and for R12. No ticket waits on #14.
- **F3. Replacing a license needs a new model write path.** `License.update` forces `updatedAt` to now
  and cannot set `createdAt` (`private(set)`). R8 and D3 (file dates kept on replace) are impossible
  without a new method in `Sources/Model/License.swift`. It is a method, not a stored property: no
  schema change, no migration.
- **F4. `applySerial` and `restoreSerial(.absent)` of `SwiftDataLicenseRepository` must not be reused
  for import.** `applySerial` deletes the item when the new serial is empty, which breaks "an import never
  deletes a Keychain item". The import path has its own serial rules (2.3).
- **F5. Pre-existing orphan items.** A Keychain item can exist under an id that has no license (residue
  of a failed compensation, plan 0004 R12). Creating a license with that id and a non-empty file serial
  overwrites the orphan; if the metadata write then fails, D4 compensation must put the orphan back, not
  delete it. So the import reads the previous serial before every serial write, also for a new license.
- **F6. Synthesized `Decodable` accepts a missing optional key.** `struct E: Decodable { let a: String;
  let s: String? }` decodes `{"a":"x","color":"red"}` with `s == nil`. ADR 0002 section 6 and plan 0009 F1
  make `serial` and `purchaseDate` keys always present (null when unset); a missing key is
  `corruptedFile` (ADR section 5, step 6). `BackupPayload.Entry` needs a hand-written `init(from:)`.
  Unknown keys are already ignored.
- **F7. One Foundation date style accepts too much, and only locally proven.** On macOS 27.2,
  `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` parses `...00.250Z`, `...00Z`, `...00.25Z`,
  `...00.250123Z` and `...00.250+01:00`; it rejects month 13 and garbage. macOS 14 and 26 may differ.
  The import decoder checks the exact shape itself (2.4) and pins both accepted forms by tests.
- **F8. Sparse files make the 64 MiB case free.** `FileHandle.truncate(atOffset: 67_108_865)` on a file
  holding `SMBACKUP 00 02` takes 0.7 ms and 4 KB on disk; `read(upToCount: 10)` and `seekToEnd()` return
  10 and 67,108,865. A4 (above 64 MiB) and A5 use the real constant, no injectable cap.
- **F9. The test target has no resources** (`Project.swift`: `sources: ["Tests/**"]` only). The known
  fixture file is a byte literal in test support, not a bundled `.smbackup`, so `Project.swift` is not
  touched.
- **F10. `BackupKeyDerivation.key` throws `BackupExportError.encryptionFailed`** on a CommonCrypto error,
  whose text ("couldn't be encrypted") is wrong on import. The reader maps it (2.5).
- **F11. Every `LicenseRepository` conformer must implement the new method**:
  `SwiftDataLicenseRepository`, `InMemoryLicenseRepository`, `UnavailableLicenseRepository` (Sources),
  `ScriptedLicenseRepository` (`Tests/Support`), `GatedLicenseRepository`
  (`Tests/LicenseStoreSerialAvailabilityTests.swift`). The `BackupService` stubs in
  `Tests/BackupModelTests.swift` are unaffected (the backup protocol does not change).
- **F13. D3 collides with two requirements of the approved license model SPEC.**
  `docs/specs/license-model.md` v1.2 R4: "outside the model, the only write paths are the throwing `init`
  and the throwing `update`"; R8: "`createdAt` is set once at creation and never changes". D3 (approved
  2026-11-21) keeps the file's `createdAt` on a replaced license, which needs the third write path of F3.
  The owner already decided the behaviour (D3); what was missing is the text of the older SPEC. Closed:
  `license-model.md` v1.3 (confirmed by Stefano on 2026-11-21) lists `restore` as a third write path in
  R4, used only by the import replace, and adds the import exception to R8. The R4 grep stays as it is. Delete-and-insert of the entity was
  considered and rejected: it relies on SwiftData's behaviour for a delete and insert of the same unique
  id in one save (unverified, see "R7" of `license-model-plan.md`) and changes `createdAt` all the same.
- **F14. The Failed state of the import sheet has only Close** (`ImportView`, `case .failed`), and
  `apply` is called only from the conflict step's Import button, after which the phase is `.importing`.
  So `noPendingImport` is not reachable from the GUI after a D1 failure; it needs no dedicated message.
- **F15. CI time.** About 40 derivations at 600,000 iterations across T2 and T3 (each `prepareImport`
  derives once; `BackupFileBuilder` derives once per sealed file unless it reuses a key it computed for
  the same salt and password). At about 0.07 s each (F3 of plan 0009, M5 Max) that is about 3 s locally,
  more on the CI runner. A6's payload variants run on the pure `decodeForImport`, with only two sealed
  end to end.
- **F12. Two existing tests assert the "not available" import** (`Tests/EncryptedBackupServiceTests.swift`,
  `exportIsAvailableAndImportIsNot`, `importMethodsThrowNotAvailable`). They are rewritten on the new
  behaviour (availability true; A13), never disabled or deleted without replacement.
- **F16. On the actor's executor, a cancel waits for the derivation.** `EncryptedBackupService` is an
  actor; `export` calls `deriveKey` synchronously on the actor's executor. If `prepareImport` did the
  same, a `cancelImport()` issued during the derivation would queue until the read finished. R17 would
  still hold (the generation counter, or simply the order, leaves no payload pending), but the cancel
  would not take effect during the read, and an A16 seam that waits for the cancel to complete before
  releasing the derivation would deadlock; only a seam that releases right after issuing the cancel
  works. Prototype on 2026-11-21 (macOS 27.2, `-swift-version 6`): with the read inline the cancel was
  still pending after 2 s while the derivation was held (R17 held once it was released); with the read in
  `Task.detached { ... }.value` the cancel ran at once and the generation counter left no payload
  pending. Choice: `prepareImport` awaits the reader in a detached task (2.7), so the cancel takes effect
  during the read and A16 is deterministic. A side note for the tests: `DispatchSemaphore.wait()` is unavailable from async
  contexts in Swift 6; the blocking seam is the synchronous `deriveKey` closure, the test side signals
  and waits through a synchronous helper or an async-friendly gate.
- **F17. `BackupService` conformers** (grep `: BackupService` on 2026-11-21): `EncryptedBackupService`,
  `InMemoryBackupService` (Sources/Fakes), `UnavailableBackupService` (Sources/Support),
  `FailingExportService` (private, `Tests/BackupModelTests.swift`). `InMemoryBackupService` today keeps
  no pending state: `applyImport` works without a `prepareImport`, and
  `InMemoryBackupServiceTests.conflictPolicyDrivesSummary` (`Tests/LicenseStoreTests.swift`) applies
  twice after one prepare.

## 2. Design

### 2.1 Answers to the SPEC's "Open points for the Architect"

- **Repository import path.** One new requirement, `importLicense(_:serial:policy:)`, that takes a full
  record and the policy and returns what it did (2.2). The id lookup, the conflict decision and the write
  run inside the repository, under the mutation lock (I3), so no other mutation and no SwiftData upsert
  can slip between lookup and write (R7 of the license model, R8, R9).
- **Reader reuse.** A new file `BackupReader.swift` runs ADR section 5 on top of `BackupFormat` (new
  bound constants), `BackupKeyDerivation` (unchanged) and `BackupPayload` (strict decoder, 2.4). The
  service change stays small.
- **Above-64-MiB case.** Sparse file and the real constant (F8). The export-only `maxFileSize` init
  parameter is not used by import.
- **Partial-failure error.** `BackupImportError.interrupted` (2.5).
- **Ownership.** Backend: data layer and its tests (T0 to T3). Frontend: `ImportModel` reload and
  close, sheet `onDisappear`, catalog, `gui.md`, app comment (T4).
- **`cancelImport()` (SPEC v2).** T0 (backend) adds the requirement and implements it in every
  conformer of F17, the real service as a placeholder that T3 completes. T0 lands on
  `feature/encrypted-import` before the ticket branches fork, so T4 calls the new method without
  waiting for T1 to T3.
- **Shared files.** Section 4.

### 2.2 Contract change (`Sources/Contract/LicenseContract.swift`)

```swift
/// What `LicenseRepository.importLicense` did with one license of a backup.
enum LicenseImportOutcome: Equatable, Sendable {
    case created
    case replaced
    case skipped
}

protocol LicenseRepository: Sendable {
    // existing requirements unchanged
    /// Writes one license read from a backup, keeping its `id`, fields, `createdAt` and `updatedAt`
    /// exactly as given (D3). Looks `license.id` up first and never relies on the SwiftData upsert.
    /// - No license with this id: creates it; `serial` non-nil and non-empty is saved, otherwise no
    ///   Keychain item is written. Returns `.created`.
    /// - Existing id, `.skip`: changes nothing, makes no serial store call. Returns `.skipped`.
    /// - Existing id, `.replace`: replaces every field and both dates; the serial is replaced when
    ///   non-nil and non-empty, kept otherwise. Returns `.replaced`.
    /// Never deletes a Keychain item that existed before the call. One license is one unit (D4): on
    /// failure the call leaves no change of its own, except the documented compensation residue.
    func importLicense(_ license: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome
}

protocol BackupService: Sendable {
    // existing requirements unchanged
    /// Drops the payload kept by `prepareImport`, if any (D5, R17). Idempotent, never throws, writes
    /// nothing to the library or the Keychain, safe with no import in progress. After it, `applyImport`
    /// with an earlier preview fails as in R11. A `prepareImport` running when this is called leaves no
    /// pending payload once it returns. Does not stop or change an `applyImport` already running.
    func cancelImport() async
}
```

- No default implementation in the `BackupService` extension: a default no-op would let a conformer
  that keeps a payload compile without dropping it. Every conformer of F17 implements it explicitly
  (T0). A synchronous body satisfies the `async` requirement (structs, test doubles).

- `LicenseSummary` already carries every field and both dates, so no new record type.
- `docs/design/gui.md` "Contract with the data layer" shows the requirement and the enum (T4).

### 2.3 Repository implementations

**`License` (`Sources/Model/License.swift`)**

- `static func isValidProductName(_ name: String) -> Bool` (internal): the existing rule (trimmed with
  `.whitespacesAndNewlines`, not empty); `validate(productName:)` calls it. The reader uses the same
  function for D2, so a file that passes `prepareImport` cannot throw `emptyProductName` at apply.
- `func restore(productName:vendor:registeredEmail:purchaseDate:version:notes:createdAt:updatedAt:) throws`:
  validates first, then assigns every field including both dates; on throw nothing changes (same pattern
  as `update`). Doc comment: import only; app code edits through `update`.

**`SwiftDataLicenseRepository.importLicense`** (under `acquireMutationLock`, I1 to I3 as for the other
mutations). `wanted` = `serial` when non-nil and non-empty, else nil.

1. `existing = try fetchLicense(id)`.
2. `existing != nil`, `.skip`: return `.skipped`. No serial store call, no context change.
3. `existing == nil` (create):
   1. Build `License(id:..., createdAt:, updatedAt:)` from the record (throws before any write).
   2. If `wanted != nil`: `previous = try await readPreviousSerial(for: id)` (F5; `.undecodableData`
      gives `.unreadable`, any other read error stops before a write), then
      `try await serials.save(wanted, for: id)` unless `previous == .value(wanted)`.
   3. I2: `guard try fetchLicense(id) == nil` (defensive under I3; on failure compensate and throw
      `duplicateID(id)`).
   4. `modelContext.insert(license)`, `persist()`. On error: `rollback()`, compensate, rethrow.
   5. Return `.created`.
4. `existing != nil`, `.replace`:
   1. If `wanted != nil`: `previous = try await readPreviousSerial(for: id)`, save `wanted` unless equal.
   2. I2: fetch again; missing (unreachable under I3): compensate, throw `notFound(id)`.
   3. `license.restore(...)`, `persist()`. On error: `rollback()`, compensate, rethrow.
   4. Return `.replaced`.

Compensation (only when this call wrote a serial), the D4 undo of the call's own write:

| `previous` | Action | Note |
| --- | --- | --- |
| `.absent` | `try? deleteSerial(for: id)` | Deletes only the item this call created (D4). |
| `.value(old)` | `try? save(old, for: id)` | Puts back the pre-existing item (replace, or an orphan, F5). |
| `.unreadable` | nothing | Previous value unknown; new value stays (same as `update`, D9 of plan 0004). |

A failed compensation leaves residue, as for `create` and `update`; the original error is thrown. The
import path calls `deleteSerial` only as compensation of an item this same call created
(`previous == .absent`), in the create branch or in the replace branch (a license with no local item and
a non-empty file serial). It never deletes an item that existed before the call. `applySerial` and
`restoreSerial` are not reused (F4). A null or `""` file serial on a new license with an orphan item under the same id leaves
the orphan in place (never deleted); the new license then shows that serial. Accepted edge, documented
in a code comment.

**`InMemoryLicenseRepository.importLicense`**: same outcomes and serial rules (no delete, `""` as nil,
skip changes nothing), honours `failure`. No compensation needed (no partial state).

**Stubs**: `UnavailableLicenseRepository` throws its existing unavailable error;
`ScriptedLicenseRepository` and `GatedLicenseRepository` throw their unsupported error (they are not
used for import).

### 2.4 Format bounds and payload decoding

**`BackupFormat`** (add, no change to existing members):

```swift
static let importIterationRange: ClosedRange<UInt32> = 600_000...10_000_000   // ADR 0002 section 4
static let importSaltLengthRange: ClosedRange<Int> = 16...64
static let firstReadLength = 10        // magic + version
```

**`BackupPayload`**

- `Entry.init(from:)` hand-written: every key of ADR section 6 is required to be present. `id`, `productName`,
  `vendor`, `registeredEmail`, `version`, `notes`, `createdAt`, `updatedAt` decode as non-optional;
  `purchaseDate` and `serial` must be present (`container.contains`, else `keyNotFound`) and may be null.
  Unknown keys ignored. The `serial` value is kept as read (`""` stays `""` here; it is treated as nil at
  apply, 2.3).
- `makeDecoder()` widened (the existing comment says #10 does it): the date string must match exactly
  `yyyy-MM-dd'T'HH:mm:ss'Z'` or `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` (length 20 or 24, `T` at 10, `Z` last,
  digits and separators in place, checked by a small pure function, no regex dependency), then it is
  parsed with the fractional style (24) or the plain style (20). Anything else, including other digit
  counts and UTC offsets (F7), is `dataCorrupted`. Decision P1: stricter than what Foundation accepts,
  exactly the two forms ADR section 6 names. Export output is unchanged, so #9's round trips keep passing.
- `static func decodeForImport(_ plaintext: Data) throws(BackupError) -> BackupPayload`: decodes with
  `makeDecoder()`; any error, a duplicate `id`, or a `productName` failing `License.isValidProductName`
  (D2) gives `BackupError.corruptedFile`. Pure, no I/O.

### 2.5 Errors

```swift
/// Failures of an import that are not a `BackupError` (docs/plans/0010-encrypted-import-plan.md, 2.5).
/// Never carries the password, the key, the payload or a serial.
enum BackupImportError: Error, Equatable, Sendable {
    /// `applyImport` without a matching pending payload (R11, also after `cancelImport()`, R17).
    /// No dedicated message.
    case noPendingImport
    /// CommonCrypto failed while deriving the key (system failure, F10). No dedicated message.
    case keyDerivationFailed
    /// A write failed on one license; earlier ones stay written (D1).
    case interrupted(imported: Int, replaced: Int, underlyingMessage: String)
}
```

- `LocalizedError`: only `interrupted` has a message, composed as
  `String(localized: "The import stopped. Imported: \(imported). Replaced: \(replaced).")` + `" "` +
  `underlyingMessage`. Catalog key `The import stopped. Imported: %lld. Replaced: %lld.`. The other two
  cases return nil and show the generic system text, as the project does for every error without a
  dedicated message (`gui.md`, Known gaps). Both are unreachable from the GUI in normal use.
- `underlyingMessage` is the failing error's `localizedDescription`, captured in the service. Repository
  and serial store errors carry no data (`SerialStoreError`, `LicenseRepositoryError`); a SwiftData save
  error shows its system text (review point for R13).
- Strings, confirmed by the Lead on 2026-11-21:

| Key | English | Italian |
| --- | --- | --- |
| `The import stopped. Imported: %lld. Replaced: %lld.` | The import stopped. Imported: N. Replaced: N. | L'importazione si è interrotta. Importate: N. Sostituite: N. |

  The "Imported: N" form avoids plural variants in both languages and matches the existing summary
  strings (`Imported: %lld`).

### 2.6 Reader (`Sources/Data/Backup/BackupReader.swift`, new)

```swift
enum BackupReader {
    /// ADR 0002 section 5, steps 1 to 6, in order, stopping at the first failure.
    /// Synchronous and CPU bound: called only from `EncryptedBackupService`.
    static func read(
        from url: URL, password: String,
        deriveKey: (String, Data, UInt32) throws -> SymmetricKey
    ) throws -> BackupPayload
}
```

1. `FileHandle(forReadingFrom:)` (open errors rethrown unchanged: generic message). `read(upToCount: 10)`:
   fewer than 10 bytes or magic not `SMBACKUP` -> `corruptedFile`.
2. Version (big-endian `UInt16` at 8): `0` -> `corruptedFile`; above `BackupFormat.version` ->
   `unsupportedVersion`. Nothing else read yet.
3. `seekToEnd()`: above `BackupFormat.maxBackupFileSize` -> `corruptedFile`.
4. Seek to 0, `read(upToCount: BackupFormat.maxBackupFileSize + 1)` (never `readToEnd()`, so a file
   that grew after step 3 is not read whole into memory); more than `maxBackupFileSize` bytes ->
   `corruptedFile`. Parse by `BackupFormat` constants: fewer than 16 bytes or fewer than `33+S` (cut
   header), KDF id not `0x01`, iterations outside `importIterationRange`, salt length outside
   `importSaltLengthRange`, cipher id not `0x01`, or `data.count != 33+S+L+16` -> `corruptedFile`. The
   length is checked on the bytes actually read, so a file that changed after step 3 is still caught.
5. Empty password -> `wrongPassword` without deriving (the service accepts any non-empty password, R3;
   the GUI never sends an empty one). `deriveKey(password, salt, iterations)`;
   `BackupExportError.encryptionFailed` -> `BackupImportError.keyDerivationFailed`. Open
   `AES.GCM.SealedBox(nonce:ciphertext:tag:)` with bytes `[0, 33+S)` as associated data; any CryptoKit
   error -> `wrongPassword` (ADR known limit).
6. `BackupPayload.decodeForImport(plaintext)` (2.4).

No `print`, `Logger` or `os_log`. The password, key and plaintext are locals.

### 2.7 Service (`EncryptedBackupService.swift`)

```swift
private struct PendingImport: Sendable { let url: URL; let entries: [BackupPayload.Entry] }
private var pendingImport: PendingImport?
private var importGeneration = 0        // bumped by every prepareImport and cancelImport (R17)

nonisolated var isImportAvailable: Bool { true }

func prepareImport(from url: URL, password: String) async throws -> ImportPreview {
    pendingImport = nil                                         // D5: a new prepare drops the old payload
    importGeneration &+= 1
    let generation = importGeneration
    let deriveKey = self.deriveKey
    let payload = try await Task.detached {                     // F16: the actor stays free for a cancel
        try BackupReader.read(from: url, password: password, deriveKey: deriveKey)
    }.value
    let existing = Set(try await repository.fetchAll().map(\.id))   // read only, R4
    let conflicts = existing.intersection(payload.licenses.map(\.id))
    if generation == importGeneration {                         // R17: no cancel or newer prepare since
        pendingImport = PendingImport(url: url, entries: payload.licenses)
    }
    return ImportPreview(fileURL: url, licenseCount: payload.licenses.count, conflictingIDs: conflicts)
}

func cancelImport() {
    pendingImport = nil                                         // D5, R17
    importGeneration &+= 1                                      // a running prepare will not store its payload
}

func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary {
    let pending = pendingImport
    pendingImport = nil                                         // D5, R11: before the first await
    guard let pending, pending.url == preview.fileURL, pending.entries.count == preview.licenseCount
    else { throw BackupImportError.noPendingImport }
    // file order; each license is one repository call (D4); stop at the first error (D1)
    ...
    // catch: throw .interrupted(imported:, replaced:, underlyingMessage: error.localizedDescription)
    return ImportSummary(imported:, replaced:, skipped:)
}
```

- `deriveKey` is the init closure from #14 (F2, merged); the reader gets the actor's stored closure,
  which is `@Sendable`. `BackupPayload` is already `Sendable`, so the detached task's result crosses back.
- R17: the generation counter covers a cancel at any suspension point of `prepareImport` (the detached
  read and `fetchAll()`) and also a second `prepareImport` overlapping the first (D5: the newer one
  wins). A `prepareImport` cancelled this way still returns its preview or its error (R17 "whatever it
  returns"); only the pending payload is withheld. An `applyImport` running when `cancelImport()` arrives
  already took and cleared the payload before its first await, so the cancel finds nothing and does not
  touch it.
- The detached task does not inherit the caller's task cancellation; cancelling an import from the GUI
  goes through `cancelImport()`, not task cancellation, so nothing changes for the user.
- Decision P2: preview conflicts are the intersection of the file's ids with the ids returned by
  `fetchAll()`. That is a lookup by id with no write, which is what R5 and the ticket's R7 rule protect;
  a dedicated `existingIDs` requirement would add protocol surface for the same result. The Lead aligns
  the SPEC wording of R5 with this. The authoritative lookup is the repository's, per license, at apply
  time (R9), so the summary reflects the library when `applyImport` runs.
- An empty file gives `0 / 0 / 0` (R9, A12).
- Reading, derivation and decryption run in the detached task, off the main thread (R12, probed in T3).
- **R12 for repository writes: D7 of SPEC v2.** Release creates `SwiftDataLicenseRepository` in
  `SerialManagerApp.init`, on the main thread, and plan 0004 (2.2, "Context thread") notes that its model
  context may then run on the main queue. SPEC v2 records this as D7 and narrows R12: the per-license
  writes of `applyImport` may run on the main queue. Moving the repository off the main thread is a
  separate change to `LicenseLibrary`, out of scope. Valid once Stefano confirms SPEC v2.
- The doc comment of the type is updated (import implemented).

### 2.8 GUI (`ImportModel`, `ImportView`, catalog, docs)

- `ImportModel.apply`: in the `catch`, `await store.load()` before `phase = .failed(...)`, so licenses
  written before the stop appear (R10).
- `ImportModel.close() async` (R17, A17): the one place that calls `service.cancelImport()`. It sets
  `isClosed = true` and calls `cancelImport()` once, unless `apply` has started (`applyStarted`, set by
  `apply` before its first await) or `close()` already ran. `unlock()` checks `isClosed` after
  `prepareImport` returns (success or error): a closed model neither auto-applies (no-conflict path) nor
  moves to `.conflicts`, so a sheet closed during Checking writes nothing, and it calls `cancelImport()`
  once more. That second call covers the service running the close's cancel before the earlier
  `prepareImport` (enqueue order across tasks on an actor is FIFO in practice at equal priority, not
  guaranteed); `cancelImport()` is idempotent, so it costs nothing otherwise.
- `ImportView`: the root `Group { switch model.phase }` becomes `VStack(spacing: 0) { switch ... }` (one
  child at a time, same layout, `.frame(width: 460)` unchanged), and
  `.onDisappear { Task { await model.close() } }` is attached to that `VStack`. A modifier on a `Group`
  applies to each child, so on the `Group` it would fire when the phase swaps a branch
  (Checking -> Conflicts drops the password form) and the Import button at the conflict step would then
  fail with `noPendingImport` (review round 3). The `VStack` keeps one identity for the whole life of the
  sheet. Not at the `ContentView` call site: whether a modifier on `ImportView` is distributed over the
  `Group` of its body was not verified, while a container inside the view leaves no doubt. Cancel at the password, checking and
  conflict steps keeps calling only `dismiss()`, so every way the sheet closes (Cancel, `Esc`, Done,
  Close, the sheet replaced) reaches `close()` and the rule lives in the model, where it is testable.
  Done and Close come after `apply` started, so they do not cancel.
- `#Preview("...conflicts")`: built with `.conflicts(samplePreview)` and a fake that never prepared that
  URL, so Import in the canvas would now fail. The preview helper prepares the fake with
  `samplePreview.fileURL` and the sample password before showing the conflicts phase (preview only, no
  app behaviour).
- `AppCommands` unchanged: Import is already enabled from `importAvailable` only, also with an empty
  library (R14).
- `SerialManagerApp` header comment: Import is real in Release (no code change; the Release branch
  already builds `EncryptedBackupService`).

## 3. Tickets

Owners: **backend** = data layer and its tests; **frontend** = GUI, catalog, design doc, app comment;
**QA** = checklist draft and verification (read-only). Branches `feature/encrypted-import-backend` and
`feature/encrypted-import-frontend` off `feature/encrypted-import`, merged back by the Git agent. T0 is
merged into `feature/encrypted-import` before both ticket branches fork (section 4).

### T0. `cancelImport()` contract and every conformer (backend, first)

- Goal: 2.2 (`BackupService.cancelImport()`), implemented in every conformer of F17, so that the
  backend and frontend branches both start from a contract that already has it.
- Files: `Sources/Contract/LicenseContract.swift` (`BackupService` requirement only),
  `Sources/Fakes/InMemoryBackupService.swift`, `Sources/Support/UnavailableBackupService.swift`,
  `Sources/Data/Backup/EncryptedBackupService.swift` (placeholder method only),
  `Tests/BackupModelTests.swift` (`FailingExportService`: the new method only),
  `Tests/LicenseStoreTests.swift` (`InMemoryBackupServiceTests`: new tests appended).
- Implementations:
  - `InMemoryBackupService` (R17, "the fake implements the same rule"): `private var pendingURL: URL?`;
    `prepareImport` clears it first and sets it to `url` on success; `cancelImport()` clears it;
    `applyImport` throws a private fake error (generic text) when `pendingURL != preview.fileURL`. The
    fake keeps the pending state after an apply (it does not model R11's single use, which is tested on
    the real service, A13), so `conflictPolicyDrivesSummary` (two applies after one prepare) and every
    existing `ImportModelTests` stay green unchanged. It uses no type from T2.
  - `UnavailableBackupService`, `FailingExportService`: empty body (nothing is ever pending).
  - `EncryptedBackupService`: empty body with a comment ("no payload is kept until import lands, T3");
    T3 replaces it.
- Tests (A15 on the fake): prepare, `cancelImport()`, apply with that preview -> throws, repository
  unchanged; `cancelImport()` twice, and with nothing prepared, does not throw; prepare again after a
  cancel -> apply works; `UnavailableBackupService().cancelImport()` returns.
- Depends on: nothing. Small; merged before T1 and T4 fork.
- Done when: build and tests green; `grep -rn ": BackupService" Sources Tests` lists only conformers
  that implement `cancelImport()` (the compiler enforces it, no default implementation).
- Covers: R17 (contract, fake), A15 (fake), R16.

### T1. Repository import path (backend)

- Goal: 2.2 and 2.3.
- Files: `Sources/Contract/LicenseContract.swift` (enum and requirement only), `Sources/Model/License.swift`,
  `Sources/Data/SwiftDataLicenseRepository.swift`, `Sources/Fakes/InMemoryLicenseRepository.swift`,
  `Sources/Support/UnavailableLicenseRepository.swift`, `Tests/Support/ScriptedLicenseRepository.swift`,
  `Tests/LicenseStoreSerialAvailabilityTests.swift` (`GatedLicenseRepository` stub only),
  `Tests/LicenseModelTests.swift` (restore tests), new `Tests/LicenseRepositoryImportTests.swift`.
- Depends on: T0 merged into `feature/encrypted-import` (both edit `LicenseContract.swift`);
  `license-model.md` v1.3 confirmed.
- Tests (SwiftData on `ModelConfiguration(isStoredInMemoryOnly: true)`, `ScriptedSerialStore`, fake data,
  dates on whole milliseconds, compared at millisecond precision):
  - create with serial: license with the given id, every field, both dates; item saved. Create with nil and
    with `""`: no save call, no item.
  - skip on an existing id: every field identical, `createdAt` and `updatedAt` included; zero serial store
    calls (log empty); `.skipped`.
  - replace with serial: every field and both dates from the record, count still 1, item replaced;
    replace with nil and `""`: fields replaced, item unchanged, no save or delete call.
  - D4 via `beforeSave` throwing: create -> no license, no item (own item removed); replace -> fields and
    dates unchanged, previous item restored; create over an orphan item -> orphan value restored;
    replace over a license with no item and a non-empty file serial -> fields and dates unchanged, no item
    (own item removed).
  - serial save failing (`ScriptedSerialStore.fail(.save, ...)`): nothing written, error rethrown unchanged.
  - previous read `undecodableData`: write proceeds; read `accessDenied`: no write, error rethrown.
  - `deleteSerial` is called only as compensation of an item this same call created
    (`previous == .absent`): asserted on the log in every test above (no delete in any success path, in
    skip, or when the item existed before the call).
  - `License.restore`: sets both dates; blank name throws and changes nothing; `isValidProductName`
    agrees with `LicenseDraft.hasValidProductName` on `""`, `"   "`, `"\n\t"`, `" a "`.
  - `InMemoryLicenseRepository.importLicense`: the three outcomes and the nil, `""` rules.
- Precondition (met): `license-model.md` v1.3 of F13, confirmed by Stefano on 2026-11-21.
- Done when: build and tests green; `grep -n "insert(" Sources/Data/SwiftDataLicenseRepository.swift`
  shows the insert only in `create` and the create branch of `importLicense`, each after a nil lookup.
- Covers: R6, R7, R8 (repository part), D3, D4.

### T2. Reader and payload validation (backend)

- Goal: 2.4 (decoder), 2.5 (error type and message), 2.6.
- Files: `Sources/Data/Backup/BackupFormat.swift` (constants only), `Sources/Data/Backup/BackupPayload.swift`,
  new `Sources/Data/Backup/BackupReader.swift`, new `Sources/Data/Backup/BackupImportError.swift`,
  new `Tests/Support/BackupImportFixture.swift`, new `Tests/Support/BackupFileBuilder.swift`,
  new `Tests/BackupReaderTests.swift`, `Tests/BackupPayloadTests.swift` (new tests appended).
- Depends on: T1 only for `License.isValidProductName` (D2); the header and crypto work starts at once.
- Fixture (F9): `BackupImportFixture.bytes`, a `[UInt8]` literal of a v1 file made once with password
  `sample-backup-pass`, salt `A0...AF`, nonce `10...1B`, `exportedAt` 2026-01-01T10:00:00.750Z, holding
  "Sample Editor" (serial `FAKE-0000-0000-0000`, `purchaseDate` null) and "Sample Viewer" (serial null),
  fields as `BackupFixtures`. The implementer generates it once (for example from a throwaway run of the
  export with those inputs), pastes the hex, and records how in a comment. Tests never call the production
  export to build it. A sanity test parses it with the existing `BackupFileReader`.
- `BackupFileBuilder` (test only): writes header fields by the literal offsets of ADR section 3 with any
  version, ids, iterations, salt and length, and seals any plaintext with the production KDF, for A4 and A6.
- Tests (temporary directory per test, fake data):
  - A1 reader part: the fixture decodes into the expected two entries, dates at millisecond precision.
  - A3: `sample-backup-paSS` -> `wrongPassword`.
  - A4: 9-byte file; magic `SMBACKUQ`; version 0; KDF id `0x02`; iterations 599,999 and 10,000,001; salt
    length 15 and 65 (with a consistent total size); cipher id `0x02`; header cut; one byte removed from the
    end; one byte appended; sparse file above 64 MiB with a valid v1 start (F8): all `corruptedFile`, and
    the injected `deriveKey` is never called.
  - A5: version 2, KDF id `0x02`, sparse size above 64 MiB -> `unsupportedVersion`, `deriveKey` never
    called; version 2 in a 10-byte file -> `unsupportedVersion`.
  - A7: a file sealed by `BackupFileBuilder` with `cafe\u{301}-sample-pw` (decomposed) opens with
    `caf\u{E9}-sample-pw` (precomposed) and decodes.
  - Bound edges on the pure ranges: 600,000 and 10,000,000 accepted, 16 and 64 accepted (no derivation at
    10,000,000).
  - A6 on the pure `decodeForImport` (F15): duplicate id; missing `createdAt`; missing `serial` key;
    missing `purchaseDate` key; `"id": "not-a-uuid"`; `productName` `"   "`; not JSON; not UTF-8;
    `licenses` not an array: all `corruptedFile`. Extra key `"color": "red"` plus dates without
    fractions: decodes. End to end through a sealed file: duplicate id (`corruptedFile`) and the extra-key
    payload (decodes).
  - Dates (P1): `.250Z` and `Z` forms accepted; `.25Z`, `.250123Z`, `+01:00`, month 13 rejected.
  - Empty password -> `wrongPassword`, `deriveKey` never called.
  - `keyDerivationFailed` when `deriveKey` throws `BackupExportError.encryptionFailed`.
  - Missing file: the open error is rethrown, not mapped to a `BackupError`.
  - `BackupImportError` message: `interrupted(2, 0, "X")` equals
    `String(localized: "The import stopped. Imported: \(2). Replaced: \(0).") + " X"`, the expectation
    built the same way as the code, never an English literal (convention of `Tests/ErrorMessageTests.swift`:
    the tests pass in any system language); the other two cases have no `errorDescription`.
  - Existing #9 round-trip and payload tests stay green unchanged.
- Never commits `Resources/Localizable.xcstrings` (frontend owns it; key in 2.5).
- Done when: tests green; `grep -rn "print(\|Logger\|os_log" Sources/Data/Backup` finds nothing.
- Covers: R1, R2, R3, R13 (reader), D2; A3 to A7 at reader level.

### T3. Service prepare and apply (backend)

- Goal: 2.7, including the real `cancelImport()` (replaces T0's placeholder) and the detached read (F16).
- Files: `Sources/Data/Backup/EncryptedBackupService.swift`, `Tests/EncryptedBackupServiceTests.swift`
  (the two tests of F12 rewritten), new `Tests/EncryptedBackupImportTests.swift`,
  `Tests/Support/BackupTestSupport.swift` (import helpers only, on top of #14's `stageProbe`).
- Depends on: T0, T1, T2.
- Tests (real service, SwiftData repository on an in-memory store with `ScriptedSerialStore` or
  `InMemorySerialStore`, never the real Keychain, 600,000 real iterations):
  - A1: fixture into an empty library: preview `2`, no conflicts; apply `2 / 0 / 0`; both licenses with
    every field and dates at millisecond precision; serial store holds `FAKE-0000-0000-0000` for the
    first id and no item for the second.
  - A2: export three fake licenses (one with no serial) with `EncryptedBackupService`, import into a new
    empty library with the same password: same ids, fields, dates, serials; `3 / 0 / 0`.
  - A3, A4 (one representative corruption), A5 at service level: library snapshot (`fetchAll` sorted by id)
    and serial store items equal before and after; serial store log has no save or delete (R4).
  - A8, A9 (`.skip`, `.replace` with serial, `.replace` with null and `""`), A10, A12.
  - R9: a conflict that appears between preview and apply (license inserted after `prepareImport`) is
    counted by apply; a conflict removed after preview is counted as imported.
  - A11: five licenses, `ScriptedSerialStore.fail(.save, with: .accessDenied, after: 2)`: error is
    `.interrupted(imported: 2, replaced: 0, underlyingMessage: <accessDenied text>)`; first two present
    with serials, third to fifth absent, no item for the third; the message contains neither a serial
    nor a product name. Running prepare again on the same file: 2 conflicts.
  - A11 with a replace before the stop: counts `imported` and `replaced` separately.
  - A13: `applyImport` with no prepare; second apply with the same preview; a preview with another
    `fileURL`: `noPendingImport`, nothing written. After a failed apply, a second apply also gives
    `noPendingImport` (D5).
  - D5: a failed `prepareImport` after a successful one drops the first payload (apply ->
    `noPendingImport`).
  - R12: from a `@MainActor` test, the `deriveKey` probe of #14 records `Thread.isMainThread == false`
    during `prepareImport`.
  - A15 (real service): prepare the fixture, `cancelImport()`, apply with that preview ->
    `noPendingImport`; library snapshot and serial store items unchanged, store log without save or
    delete. `cancelImport()` twice and with nothing prepared: no throw, nothing written.
  - A16: the `deriveKey` seam signals "entered" and blocks (synchronously, F16) until the test has
    awaited `cancelImport()`; then it releases. `prepareImport` returns its preview; apply with it ->
    `noPendingImport`; nothing written. The test fails by timeout, not by hanging, if the cancel cannot
    run while the derivation is held (bounded wait in the seam).
  - R17 ordering: a second `prepareImport` started while the first is held in the seam leaves only the
    second payload pending (the first preview's apply -> `noPendingImport` when its `fileURL` differs, or
    the counts of the second file are applied when it is the same file).
  - `isImportAvailable == true`, `isExportAvailable == true` (rewrite of F12).
- Done when: tests green locally and on CI (Debug test plus Release build).
- Covers: R4, R5, R6 to R11, R12, R14 (service flag), R16, R17 (real service); A1, A2, A8 to A13, A15,
  A16.

### T4. Reload on failure, cancel on close, strings, docs (frontend)

- Goal: 2.8, catalog, `gui.md`.
- Files: `Sources/Store/BackupModels.swift` (`ImportModel` only), `Sources/Views/ImportView.swift`
  (root container, `onDisappear`, conflicts preview only), `Tests/BackupModelTests.swift` (`ImportModelTests`, new tests and one test
  double), `Resources/Localizable.xcstrings`, `docs/design/gui.md`, `Sources/SerialManagerApp.swift`
  (header comment only).
- Depends on: T0 only (`cancelImport()` in the contract and in the fake). The key of 2.5 is fixed; the
  contract text in `gui.md` follows T1's final signature. Forks after T0 is merged and runs in parallel
  with T1 to T3; it compiles on its own branch because it uses no type created by T1 to T3.
- Test double (in `Tests/BackupModelTests.swift`): `RecordingBackupService`, an actor that counts
  `cancelImport()` calls, can hold `prepareImport` until released, and can script `applyImport` to
  create one license in the `InMemoryLicenseRepository` behind the store and then throw a local test-only
  error (`struct StoppedImport: LocalizedError` with a fake `errorDescription`), not `BackupImportError`
  (created by T2; `ImportModel` reads only `localizedDescription`).
- Tests:
  - Reload (R10): after the failing `apply`, `store.licenses` contains the license and `phase` equals
    `.failed(thrownError.localizedDescription)`, read from the thrown error, never a literal.
  - A17: `close()` at `.password` and at `.conflicts` -> exactly one `cancelImport()`; `close()` twice
    -> one call. `close()` while `unlock()` is held in `prepareImport` (Checking) -> one call at close,
    and once `prepareImport` is released one more from `unlock()` (2.8), no `applyImport` call, the phase
    does not move to `.conflicts`. `close()` after `apply` started (`.done`, `.failed` from apply) ->
    zero calls.
  - No cancel on the way forward: password -> checking -> conflicts -> importing -> done, without
    `close()`, records zero `cancelImport()` calls and the apply succeeds.
  - Existing `ImportModelTests` stay unchanged.
- View: root `VStack(spacing: 0)` instead of `Group`, `.onDisappear { Task { await model.close() } }` on
  it; Cancel buttons keep `dismiss()` only (2.8). There is no view-test harness in the project, so the
  placement is checked by review and by a Debug-app step (QA, section 7): the Debug fake has two
  conflicts, so File > Import Licenses..., sample password, Conflicts step, Import must end on "Import
  Complete" with counts. With `onDisappear` on the `Group` it ends on "Import Failed" (the fake now
  rejects an apply after a cancel, T0), so this step catches the regression.
- Conflicts preview: the helper prepares the fake first (2.8).
- Catalog: the key of 2.5 with `en` and `it`; check that every existing import string has `it`.
- `gui.md`: Import (real import in Release, Skip/Replace semantics including "serial kept when the backup
  has none", partial-failure message, list reloaded after a failure, Cancel and every close before
  Import call `cancelImport()` so the decrypted payload is dropped at once, D5 revised); "Contract with
  the data layer" (`importLicense`, `LicenseImportOutcome`, `cancelImport()`);
  Known gaps (remove "Import stays disabled until #10"; a tampered file reports a wrong password, ADR
  known limit; an orphan Keychain item under the id of a newly imported license whose file serial is
  null or `""` is kept, so that license shows the orphan serial: accepted behaviour, 2.3).
- Done when: tests green; `plutil -lint Resources/Localizable.xcstrings`; the new key has `it`.
- Covers: R10 (sheet), R14 (comment), R15, R17 (sheet); A17.

### T5. Owner-run Release checklist (QA drafts, frontend commits)

- Goal: D6: `docs/qa/encrypted-import-release-checklist.md`, same pattern as
  `docs/qa/encrypted-export-release-checklist.md`, run only by Stefano on a signed Release build.
- Content: A14 (empty library, Import enabled, fixture or a fresh export imported, "Imported: 2", serial
  revealed in the detail); wrong password inline; a non-backup file gives the corrupted message; Skip and
  Replace on an export of the same library; Keychain prompt denied during apply gives Import Failed with
  counts and the list shows what was imported; re-running the import shows conflicts; Cancel at the
  conflict step writes nothing (library unchanged after reopening the import).
- Depends on: T3, T4.
- Covers: R14 (A14), D6.

### Coverage

| Req | Tickets | Verification |
| --- | --- | --- |
| R1 | T2, T3 | Reader tests A3 to A5 with `deriveKey` probe; sparse 64 MiB file; service-level snapshots |
| R2 | T2 | A6 payload tests, date-form tests (P1), missing-key tests (F6) |
| R3 | T2 | A7 (NFD file, NFC password), empty-password test; NFC already pinned by #9 literal tests |
| R4 | T3 | Library and serial store snapshots plus empty write log on every prepare failure |
| R5 | T3 | A1, A8 previews; conflicts by id |
| R6 | T1, T3 | Repository create tests; A1, A2, A10 |
| R7 | T1, T3 | Skip test with zero serial store calls and identical dates; A8 |
| R8 | T1, T3 | Replace tests (count 1, file dates); A9; review of the insert grep |
| R9 | T3 | Conflict appearing or vanishing between preview and apply; A12; sum equals `licenseCount` |
| R10 | T1, T3, T4 | D4 compensation tests; A11; `ImportModel` reload test |
| R11 | T3 | A13, D5 and A15 tests (apply after cancel fails as in R11) |
| R12 | T3 | `Thread.isMainThread` probe through `deriveKey` (read, derive, decrypt, in the detached task); writes per D7 (2.7) |
| R13 | T2, T3 | Review; grep of `Sources/Data/Backup`; A11 message contains no serial or name |
| R14 | T3, T4, T5 | `isImportAvailable` test; CI Release build; review of `AppCommands`; owner checklist A14 |
| R15 | T4 | Review of `gui.md` (including `cancelImport()` on Cancel and close) and catalog (`en` and `it`) |
| R16 | T0 to T4 | CI green, no disabled test (F12 rewrites reviewed, existing fake tests unchanged), grep for real-looking data |
| R17 | T0, T3, T4 | A15 on the fake (T0) and on the real service (T3); A16 with the `deriveKey` seam (T3); A17 with the recording double (T4); review of `ImportView.onDisappear` and of the generation counter |

## 4. Parallelism and shared files

```
4efff0c ──> T0 (backend, merged first) ──> T1 (backend) ──> T2 (backend) ──> T3 (backend) ──┐
                                       └──> T4 (frontend, in parallel) ──────────────────────┴──> T5 (QA + frontend) ──> QA
```

T0 is small (one requirement, four one-method conformers, a few fake tests) and is merged into
`feature/encrypted-import` before the backend and frontend branches fork. With one backend agent T1 to
T3 then run in sequence; T2's header and crypto parts do not need T1 and can start first if T1 is
blocked. T4 runs alongside T1 to T3 and compiles standalone on top of T0 (finding 1 of the v1 review
stays closed: its tests use only T0's contract and local test types).

| File | Owner | Also touched by | Rule |
| --- | --- | --- | --- |
| `Sources/Data/Backup/EncryptedBackupService.swift` | backend (T3) | T0 (placeholder `cancelImport`) | T0 first, T3 replaces the body; builds on #14's `deriveKey`. |
| `Sources/Fakes/InMemoryBackupService.swift`, `Sources/Support/UnavailableBackupService.swift`, `Tests/LicenseStoreTests.swift` | backend (T0) | none | T0 only. |
| `Sources/Store/BackupModels.swift`, `Sources/Views/ImportView.swift` | frontend (T4) | none | `ImportModel`; root container, `onDisappear` and conflicts preview only. |
| `Tests/EncryptedBackupServiceTests.swift`, `Tests/Support/BackupTestSupport.swift` | backend (T3) | none open | Only the F12 rewrites; import tests go in a new file. |
| `Resources/Localizable.xcstrings` | frontend (T4) | none | Backend never commits it; a build-extracted change is reverted by an inverse edit. |
| `docs/design/gui.md` | frontend (T4) | none open | Edit after T1's signature is final. |
| `Sources/SerialManagerApp.swift` | frontend (T4) | none | Comment only. |
| `Sources/Contract/LicenseContract.swift` | backend (T0 `BackupService`, T1 `LicenseRepository`) | none | Additive only; T0 merged before T1 forks. |
| `Sources/Model/License.swift` | backend (T1) | none | Additive only. |
| `Tests/BackupModelTests.swift` | frontend (T4) | T0 (`FailingExportService` one method) | T0 merged before T4 forks; other backend tests go in new files. |

## 5. Branch hygiene

- Done: `feature/encrypted-import` fast-forwarded to `origin/main` `4efff0c` (#14 included), with
  Stefano's authorization. If `main` moves again before the merge back, the Git agent rebases with the
  owner's authorization.
- The SPEC, `license-model.md` v1.3 and this plan are committed in one `docs:` commit on `feature/encrypted-import` after PLAN
  approval, before T0 (Git agent; not committed by the Architect). Then T0 on its own short branch,
  merged into `feature/encrypted-import`; then the backend and frontend branches fork.
- `PROJECT_BRIEF.md` "Status" is updated after the merge, in a separate docs change, as for #9.

## 6. Open points for the Lead

1. Closed: F13, `license-model.md` v1.3 confirmed by Stefano on 2026-11-21.
2. Closed: strings of 2.5 confirmed by the Lead.
3. Closed: #14 merged, no ticket waits on it.
4. Closed: branch fast-forwarded to `4efff0c`.
5. Closed: SPEC v2 confirmed by Stefano (D5 revised, D7, R17); D7 covers the R12 writes of 2.7. To
   note for the review: A17 says each close calls `cancelImport()` "once"; when the sheet closes during
   Checking the model calls it once at close and once more when `prepareImport` returns (2.8, reviewer's
   suggestion for actor enqueue order). Read as "cancelled on close, never after apply started";
   `cancelImport()` is idempotent and the user sees no difference. If the Lead wants "exactly once"
   literally, the alternative is to skip the call at close during Checking and make only the one in
   `unlock()`, at the cost of the payload living until `prepareImport` returns.
6. For the review: F16 chooses where `prepareImport` runs the reader (detached task instead of the
   actor's executor). No change to the ADR 0002 check order or to the export path.
7. For the review: the fake models R17 (cancel) but not R11's single-use apply (T0), to keep the existing
   fake tests unchanged; A13 runs on the real service only.
8. Interpretations inside ADR 0002, no behaviour change, listed for the review: P1 (exactly the two date
   forms), F6 (`serial` and `purchaseDate` keys must be present, null allowed), P2 (preview conflicts via
   `fetchAll()` ids, SPEC R5 wording aligned by the Lead), empty password -> `wrongPassword` without
   derivation (2.6, step 5).

## 7. QA on the combined result

- `xcodebuild ... test` green locally and on CI; CI Release build green.
- No test disabled, deleted or weakened: the diff of `Tests/EncryptedBackupServiceTests.swift` shows only
  the two F12 rewrites; #9 round-trip and payload tests unchanged and green.
- Grep of the diff for real-looking data (serials other than `FAKE-...`, real emails, real product names).
- Review: `importLicense` never inserts without a nil lookup and calls `deleteSerial` only as
  compensation of an item this same call created (`previous == .absent`); R12 (off-main probe; writes per
  D7) and R13 in `Sources/Data/Backup`; `ImportModel.apply` reloads on failure.
- R17: every `BackupService` conformer implements `cancelImport()` (no default implementation); the real
  service's generation counter and detached read (2.7); `ImportView` calls `model.close()` only from
  `onDisappear` on the root `VStack`, never on a `Group` or a phase branch; A15 to A17 green; the A16
  test is bounded by a timeout, so CI fails rather than hangs if the pool is starved.
- Debug app, conflicts path: File > Import Licenses..., sample password, Conflicts step, Import ends on
  "Import Complete" with counts (catches `onDisappear` firing on a phase change, T4); Cancel at the
  Conflicts step and reopening shows the same conflicts again (nothing written).
- Message tests read expected texts from `String(localized:)` or the thrown error, never an English
  literal (run once with the system language set to Italian, or review).
- T5 checklist prepared for Stefano and listed as owner-run in the verdict.
