# Plan: Encrypted export of licenses and serials (backlog #9)

- Plan version: v2 (v1 got CHANGES REQUESTED at PLAN review on 2026-11-20: B1 plus S1 to S5, N1 to N3)
- Date: 2026-11-21
- Input: `docs/specs/0009-encrypted-export.md` v1 (approved by Stefano on 2026-11-20, D1 to D5),
  `docs/adr/0002-backup-format.md` (normative, unchanged by this plan), `docs/adr/0001-storage.md`,
  `docs/design/gui.md`, baseline `9fa7a4b` (= `origin/main` on 2026-11-20)
- Author: Architect
- Status: v2, waiting for PLAN re-review

Changelog v1 to v2:
- B1: NFC pinned independently of the shared KDF: internal `BackupKeyDerivation.passwordBytes(_:)` with a
  literal-bytes test, and a key test against a direct `CCKeyDerivationPBKDF` call (2.4, T2, coverage R2).
- S1: `ExportModel` test of the Failed and Try Again path of A5 (T3).
- S2: `BackupExportError` message tests (T2).
- S3: `BackupRandom` gets its own file (2.4, T2).
- S4: the read-only-directory test restores `0o755` in a `defer` (T2).
- S5: only the frontend commits `Resources/Localizable.xcstrings` (T2, T3, section 4).
- N1: `minimumPasswordLength` and the hint string sit side by side with a comment (2.5).
- N2: fake dates on whole milliseconds (T2).
- N3: SPEC and plan committed on `feature/encrypted-export` before the ticket branches fork (section 5).
- Strings of 2.3 confirmed (PM note, 2026-11-20).

## 1. Findings that shape the plan

Prototypes ran on 2026-11-20 on macOS 27.2 with the local toolchain (Apple Swift 6.4.2), compiled with
`xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -O`. CI runs Xcode 26.6 on macOS 26: every
behaviour below is observed locally only, and the implementation must be green on CI.

- **F1. A synthesized `Encodable` drops nil optionals.** A `Codable` struct with `var a: String?` set to nil
  encodes as `{"d":...}`, without the key `a`. ADR 0002 section 6 requires `"serial": null` and
  `"purchaseDate": null`, and section 5 makes a missing required key `corruptedFile` on import. The payload
  entry needs a hand-written `encode(to:)` that calls `encode(_:forKey:)` (or `encodeNil`) for both optionals.
  Tests must look at the raw decrypted JSON (`JSONSerialization`, `NSNull`), because a `Codable` decode
  would read a missing key and a null the same way.
- **F2. Date format.** `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` (a Sendable value type,
  macOS 12+) formats `Date(timeIntervalSince1970: 1.5)` as `1970-01-01T00:00:01.500Z`: UTC, `Z`, exactly
  three fractional digits, as ADR 0002 section 6 requires. Used through
  `JSONEncoder.DateEncodingStrategy.custom`. It avoids `ISO8601DateFormatter`, a class shared across actors.
- **F3. KDF and NFC.** `CCKeyDerivationPBKDF(kCCPBKDF2, ..., kCCPRFHmacAlgSHA256, 600_000, ..., 32)` on
  `password.precomposedStringWithCanonicalMapping.utf8` compiles under Swift 6 and gives the same key for
  `cafe\u{301}-sample-pw` and `caf\u{E9}-sample-pw`. Measured about 0.07 s per derivation (M5 Max, `-O`),
  consistent with ADR 0002. Every real-service test derives at 600,000 iterations; there are fewer than
  15 of them, so the suite grows by about one second.
- **F4. GCM sizes.** `AES.GCM.seal(_:using:nonce:authenticating:)` on 11 bytes gives an 11-byte ciphertext
  and a 16-byte tag. The ciphertext length equals the plaintext length, so the final file size
  `33 + 16 + plaintext.count + 16` is known right after JSON encoding, before any key is derived.
- **F5. Atomic write keeps the old file.** `Data.write(to:options: .atomic)` into a directory made
  read-only (`0o555`) throws `NSCocoaErrorDomain` 513 and leaves the existing file with its old bytes.
  This is the R9 test technique for "bytes unchanged"; a destination whose parent folder does not exist
  is the technique for "not created".
- **F6. `isAvailable` is an extension-only member** (`Sources/Support/UnavailableBackupService.swift`).
  Called on `any BackupService` it is statically dispatched: a value defined by a concrete service would
  never be seen through the existential. The D1 split must use protocol requirements.
- **F7. Two existing tests break under the 12-character rule**, not one: `ExportModelTests` (both tests)
  and `UnavailableBackupServiceTests.exportFailsInsteadOfClaimingSuccess` type `sample`. With the new rule
  `ExportModel.export` returns early and the latter would never reach `.failed`. Both are updated to fake
  passwords of 12 or more characters (no test is disabled or deleted).
  `UnavailableBackupServiceTests.reportsItselfUnavailable` asserts `isAvailable`, which this plan
  replaces: it is rewritten on the new flags with the same intent.
- **F8. Fakes are too coarse for A4 and A5.** `InMemoryLicenseRepository` turns `""` into a missing
  item on save and fails every call when a failure is set (`fetchAll` included), so it can produce
  neither "an item holding `""`" nor "the Keychain fails for one license only". A test-only
  `ScriptedLicenseRepository` with a per-id serial result is needed.
- **F9. `fetchAll()` order is unspecified** (`InMemoryLicenseRepository` returns dictionary order).
  The service sorts what it exports (see 2.4); tests still compare licenses by `id`.
- **F10. The Release branch of `SerialManagerApp.init()` is not compiled by CI today**: `xcodebuild test`
  builds Debug. Backlog #13 (`chore/ci-release-build`, not merged) adds a Release build step; until it
  lands, the wiring ticket runs a local Release build.
- **F11. Live worktrees touching shared files** (diff `main...<branch>` on 2026-11-20):
  `feature/license-detail` (#7) edits `Sources/AppCommands.swift` (License menu, lines 26 to 32) and
  `docs/design/gui.md`; `feature/main-window-list-search` (#5) edits `docs/design/gui.md`;
  `chore/ci-release-build` (#13) edits `.github/workflows/ci.yml`, `docs/ci.md`, `CLAUDE.md`. None
  edits `Resources/Localizable.xcstrings` or `Sources/SerialManagerApp.swift` today.

## 2. Design

### 2.1 Answers to the SPEC's "Open points for the Architect"

- **Export error type.** A new `BackupExportError` (2.3). Errors from the repository, the serial store
  and the file write are rethrown unchanged, never wrapped, so R8 shows exactly the message the app
  already shows for that error: `SerialStoreError.accessDenied` gives "Keychain access was denied...";
  `undecodableData` and `unexpected` have no dedicated text today (`SerialStoreError+Message.swift`) and
  show the generic system text "The operation couldn't be completed...". That generic text is the
  "existing user-facing message" of R8; giving those two cases a dedicated message is out of scope.
- **Size cap tests (A6).** The service takes an internal `maxFileSize` init parameter whose default is
  the single constant `BackupFormat.maxBackupFileSize` (67,108,864). Production code never passes it.
  Tests use a small cap to exercise the failure path, plus one test that the constant is 67,108,864 and
  one that the size check accepts a file of exactly the cap and rejects cap + 1 (2.4, step 4, checked on
  the pure size function, no 64 MiB allocation). The cap is checked before the key is derived, so the
  failure path costs no PBKDF2. Iterations and import bounds stay non-injectable (ADR 0002).
- **Decryption path.** Test-only: `Tests/Support/BackupFileReader.swift` parses the file by the literal
  offsets of ADR 0002 section 3 (not through the writer's header builder, so a wrong layout cannot pass
  a round trip), derives the key with the production `BackupKeyDerivation`, opens the sealed box with
  bytes `[0, 33+S)` as associated data and returns the header fields and the plaintext. The production
  reader belongs to #10, which implements sections 4 and 5 (ordered checks, file handle, bounds, error
  mapping, payload validation) and reuses `BackupFormat`, `BackupKeyDerivation` and `BackupPayload`
  from this ticket. #10 may promote parts of the test reader, but it owns the production one.
- **Availability split (D1).** Two protocol requirements replace `isAvailable` (2.2).
- **Conflict-prone files.** One owner each (section 4), edited late and after a rebase (section 5).

### 2.2 Contract change (`Sources/Contract/LicenseContract.swift`, `UnavailableBackupService.swift`)

```swift
protocol BackupService: Sendable {
    /// False while the File menu must keep Export disabled for this service.
    var isExportAvailable: Bool { get }
    /// False while the File menu must keep Import disabled for this service.
    var isImportAvailable: Bool { get }
    func export(to url: URL, password: String) async throws -> ExportSummary
    func prepareImport(from url: URL, password: String) async throws -> ImportPreview
    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary
}

extension BackupService {
    var isExportAvailable: Bool { true }
    var isImportAvailable: Bool { true }
}
```

- They are requirements (F6), so the values of a concrete service are seen through `any BackupService`.
  An actor conforms with `nonisolated var`.
- `UnavailableBackupService`: both false. `InMemoryBackupService`: defaults (Debug keeps both menu items
  for the fake GUI, D4). `EncryptedBackupService`: export true, import false until #10.
- The `isAvailable` extension is removed. `AppCommands` takes `exportAvailable` and `importAvailable`
  instead of `backupAvailable`; Export stays also disabled when `store.licenses.isEmpty`.
- `docs/design/gui.md` "Contract with the data layer" shows the two properties.

### 2.3 Export error type

```swift
/// Failures of the export itself. Other errors (repository, serial store, file write) are
/// rethrown unchanged. Never carries the password, the key, the payload or a serial.
enum BackupExportError: Error, Equatable, Sendable {
    /// The file would be larger than `BackupFormat.maxBackupFileSize` (R7).
    case fileTooLarge
    /// Random bytes, key derivation or sealing failed (system failure, not user input).
    case encryptionFailed
}
```

`LocalizedError` messages (the frontend adds both languages to the catalog, see T3):

| Case | English | Italian |
| --- | --- | --- |
| `fileTooLarge` | The backup is larger than 64 MB, the maximum size. | Il backup supera i 64 MB, la dimensione massima. |
| `encryptionFailed` | The backup couldn't be encrypted. Try again. | Non è stato possibile cifrare il backup. Riprova. |

The English `fileTooLarge` text is the SPEC's (R7). `encryptionFailed` is a new string not named by the
SPEC; it covers `SecRandomCopyBytes` or `CCKeyDerivationPBKDF` returning an error status and a CryptoKit
throw, which the SPEC does not mention and which cannot happen with valid inputs. All four texts
(English and Italian) are confirmed (PM note of 2026-11-20).

### 2.4 Real service (`Sources/Data/Backup/`, new files)

- `BackupFormat.swift`: an `enum` with the v1 constants (magic `SMBACKUP`, version `1`, KDF id `0x01`,
  iterations `600_000`, salt length `16`, cipher id `0x01`, nonce length `12`, tag length `16`,
  `maxBackupFileSize = 67_108_864`), `fileSize(saltLength:ciphertextLength:) -> Int` (`33+S+L+16`) and
  `header(salt:nonce:ciphertextLength:) -> Data` (big-endian, ADR 0002 section 3).
- `BackupKeyDerivation.swift`: `static func passwordBytes(_ password: String) -> [UInt8]` (internal):
  NFC (`precomposedStringWithCanonicalMapping`), then UTF-8. `static func key(password: String, salt: Data,
  iterations: UInt32) throws -> SymmetricKey`: `CCKeyDerivationPBKDF` over `passwordBytes(password)` with
  `kCCPBKDF2` and `kCCPRFHmacAlgSHA256`, 32 bytes; a non-success status throws `encryptionFailed`.
  Synchronous; called only from the actor. #10 reuses both, so the NFC rule (ADR 0002 section 8) is
  pinned by tests that do not go through this function (T2, B1).
- `BackupRandom.swift`: `enum BackupRandom` with `static func bytes(_ count: Int) throws -> Data` over
  `SecRandomCopyBytes(kSecRandomDefault, ...)`; a non-success status throws `encryptionFailed`. Default
  salt source of the service.
- `BackupPayload.swift`: `struct BackupPayload: Codable, Equatable, Sendable` with `exportedAt: Date` and
  `licenses: [Entry]`; `Entry` carries every `LicenseSummary` field (`id`, `productName`, `vendor`,
  `registeredEmail`, `purchaseDate`, `version`, `notes`, `createdAt`, `updatedAt`) plus `serial: String?`,
  with the JSON keys of ADR 0002 section 6 and a hand-written `encode(to:)` that writes `null` for
  `purchaseDate` and `serial` (F1). `static func makeEncoder()`: `.sortedKeys`, date strategy of F2.
  `static func makeDecoder()`: the same three-digit form, used by the tests; #10 widens it to the form
  without fractions and adds validation.
- `EncryptedBackupService.swift`:

```swift
actor EncryptedBackupService: BackupService {
    init(
        repository: any LicenseRepository,
        saltSource: @escaping @Sendable (Int) throws -> Data = BackupRandom.bytes,   // SecRandomCopyBytes
        nonceSource: @escaping @Sendable () -> AES.GCM.Nonce = { AES.GCM.Nonce() },
        now: @escaping @Sendable () -> Date = { Date() },
        maxFileSize: Int = BackupFormat.maxBackupFileSize
    )
    nonisolated var isImportAvailable: Bool { false }
    func export(to url: URL, password: String) async throws -> ExportSummary
    func prepareImport(...) async throws -> ImportPreview      // throws UnavailableBackupService.NotAvailable()
    func applyImport(...) async throws -> ImportSummary         // throws UnavailableBackupService.NotAvailable()
}
```

`export(to:password:)` runs in this order and stops at the first failure; nothing is written before
step 8:

1. `fetchAll()`; sort by `createdAt`, then `id.uuidString` (stable order, byte-exact vectors possible).
2. For each license, in order, `serial(for:)`. Any thrown error is rethrown unchanged (D2, R8). nil or
   `""` becomes `serial: null` and counts in `missingSerialCount` (R3, R4). Values are not trimmed.
3. Build `BackupPayload` with `exportedAt = now()` and encode it (R3).
4. Size check: `BackupFormat.fileSize(saltLength: 16, ciphertextLength: plaintext.count)` above
   `maxFileSize` throws `fileTooLarge` (R7, F4). No key derived yet.
5. `salt = try saltSource(16)` (a count other than 16 throws `encryptionFailed`), `nonce = nonceSource()`.
6. Header `[0, 49)` from `BackupFormat.header`; key from `BackupKeyDerivation` (R2).
7. `AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)`; file = header +
   ciphertext + tag; its count equals the size of step 4 (a mismatch is a programming error:
   `assert` plus `encryptionFailed`).
8. `try file.write(to: url, options: .atomic)`; write errors rethrown unchanged (R9, F5).
9. Return `ExportSummary(licenseCount:missingSerialCount:)`.

- **R11.** The service is an `actor`, so steps 1 to 8 run on its executor, never on the main actor,
  whatever the compiler's default isolation. `ExportModel` stays in `.exporting` meanwhile (existing code).
- **R12.** No `print`, `Logger` or `os_log` in `Sources/Data/Backup/`; no error case carries data; the
  password, key and plaintext are locals that are never stored on the actor.
- **Not done here:** no service-side check of the 12-character minimum (the SPEC puts the rule in
  `ExportModel`, ADR 0002 section 8); no extra zeroing of key or plaintext memory (not required by the
  ADR; `Data` and `SymmetricKey` do not offer a reliable way to do it).

### 2.5 GUI (`ExportModel`, `ExportView`)

- `ExportModel.minimumPasswordLength = 12`, declared next to the hint string with a comment that the
  two change together (the catalog key cannot interpolate the constant without changing the confirmed
  text, N1); `canExport` is
  `password.count >= 12 && password == confirmation && phase == .entering` (`String.count` counts
  `Character`s; no trimming). `showsMismatch` unchanged.
- `ExportView`: under the two fields, always visible, `Text("Use at least 12 characters.")` in
  `.callout` and `.secondary` (D3), placed before the mismatch label. The existing explanation already
  says a forgotten password cannot be recovered (unchanged).
- Previews use fake passwords of 12 or more characters; a "short password" preview shows the disabled
  Export button with the hint.

### 2.6 Release wiring (`SerialManagerApp.swift`)

Release branch: `backupService = EncryptedBackupService(repository: repository)`, where `repository` is
the `LicenseLibrary.makeRepository()` result already built there. If the library failed to open, the
store fails, the list is empty and Export is disabled; reaching the service anyway would fail on
`fetchAll()` with the existing library message. Debug branch unchanged (D4). The header comment is
updated (Export real in Release, Import disabled until #10). The `AppCommands` call passes
`exportAvailable: backupService.isExportAvailable, importAvailable: backupService.isImportAvailable`.

## 3. Tickets

Owners: **backend** = data layer and its tests, **frontend** = GUI, app wiring, catalog, design doc.
Branches: `feature/encrypted-export-backend` and `feature/encrypted-export-frontend` off
`feature/encrypted-export`; the Git agent merges both into `feature/encrypted-export` (T1 first, as in
plan 0004).

### T1. Split backup availability (frontend)

- Goal: D1 contract change of 2.2, with no behaviour change yet (Release still on
  `UnavailableBackupService`, both items disabled; Debug both enabled).
- Files: `Sources/Contract/LicenseContract.swift` (protocol), `Sources/Support/UnavailableBackupService.swift`,
  `Sources/AppCommands.swift` (File menu hunk only), `Sources/SerialManagerApp.swift` (the `AppCommands`
  call only), `Tests/BackupModelTests.swift` (`UnavailableBackupServiceTests.reportsItselfUnavailable`
  rewritten on the two flags, F7).
- Depends on: nothing. Small; lands first so T2 can override `isImportAvailable`.
- Done when: build and tests green; `grep -rn "isAvailable\b\|backupAvailable" Sources Tests` finds
  nothing; `InMemoryBackupService` reports both true, `UnavailableBackupService` both false.
- Covers: R13 (part), D1.

### T2. Real export service (backend)

- Goal: 2.3 and 2.4, with tests.
- Files (new): `Sources/Data/Backup/BackupFormat.swift`, `BackupKeyDerivation.swift`, `BackupRandom.swift`,
  `BackupPayload.swift`, `BackupExportError.swift` (type plus `LocalizedError`),
  `EncryptedBackupService.swift`; `Tests/Support/ScriptedLicenseRepository.swift` (fixed licenses,
  per-id result: value, nil, `""` or error, F8), `Tests/Support/BackupFileReader.swift` (2.1),
  `Tests/EncryptedBackupServiceTests.swift`, `Tests/BackupPayloadTests.swift`,
  `Tests/BackupFormatTests.swift`, `Tests/BackupExportErrorTests.swift`. Edits no existing file and never
  commits `Resources/Localizable.xcstrings`, even if a build writes extracted keys into it (S5): such a
  change is discarded by an inverse edit and the keys are sent to the frontend.
- Depends on: T1 for the `isImportAvailable` requirement only; everything else starts at once.
- Tests (fake data and fake passwords only, temporary directory per test, never the real Keychain):
  - Fake dates are built on whole milliseconds (for example `Date(timeIntervalSince1970: 1_767_258_000.250)`),
    so the three-digit formatting cannot round or truncate them (N2).
  - A1: header bytes `53 4D 42 41 43 4B 55 50 | 00 01 | 01 | 00 09 27 C0 | 10`, salt, `01`, nonce, length;
    file size `33+S+L+16`; summary `2, 1`; raw JSON (F1) has both licenses, every field, dates at
    millisecond precision, `"serial": null` (NSNull) for "Sample Viewer", `"purchaseDate": null` when unset.
  - A3: export with `cafe\u{301}-sample-pw`, `BackupFileReader` opens with `caf\u{E9}-sample-pw`.
  - A4: serial `""` exported as null, counted in `missingSerialCount`; JSON never contains `"serial":""`.
  - A5: `SerialStoreError.accessDenied` for the second license: `export` throws exactly that error; the
    destination does not exist afterwards; with a pre-existing destination its bytes are unchanged.
  - A6: with `maxFileSize` small, `fileTooLarge`, no file created, pre-existing file unchanged, and the
    salt source never called (proof no KDF ran). `BackupFormat.maxBackupFileSize == 67_108_864`;
    the size check accepts a size equal to the cap and rejects cap + 1 (pure function).
  - A7: two exports with default sources give different files; with fixed salt, nonce and clock the
    header salt and nonce and the payload `exportedAt` equal the injected values.
  - A8: A1's bytes contain neither `FAKE-0000-0000-0000`, `Sample Editor` nor `user@example.com` (UTF-8);
    also `exportedAt`'s formatted string is absent.
  - A10: empty library: `"licenses": []`, summary `0, 0`.
  - R9 write error: destination in a read-only directory (F5) keeps its bytes; the test restores
    `0o755` in a `defer` so the temporary directory can be removed on CI (S4). Parent folder missing:
    no file, error rethrown.
  - R11: from a `@MainActor` test, the injected salt source records `Thread.isMainThread` and the test
    expects false.
  - NFC, pinned without the shared function (B1):
    `BackupKeyDerivation.passwordBytes("cafe\u{301}-sample-pw")` equals the literal bytes
    `63 61 66 C3 A9 2D 73 61 6D 70 6C 65 2D 70 77` (precomposed `é` = `C3 A9`), and
    `BackupKeyDerivation.key(password: "cafe\u{301}-sample-pw", salt:, iterations: 600_000)` equals a key
    computed in the test by a direct `CCKeyDerivationPBKDF` call over those literal bytes with the same
    salt. A wrong form (NFD, NFKC, no normalization) fails both.
  - KDF: the first 32 bytes of the PBKDF2-HMAC-SHA256 test vector `P = "passwd"`, `S = "salt"`, `c = 1`
    of RFC 7914 section 11, copied from the RFC text by the implementer (pins R2 independently of the
    round trip).
  - Payload: date format `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, sorted keys, `version` is the product
    version string.
  - `BackupExportError` messages, in the style of `Tests/ErrorMessageTests.swift`: `fileTooLarge` equals
    the R7 English text, `encryptionFailed` the 2.3 text; no case interpolates a value (S2, R12).
  - Import methods of the real service throw `NotAvailable`; `isImportAvailable == false`,
    `isExportAvailable == true`.
- Done when: all of the above green in `xcodebuild ... test`; `grep -rn "print(\|Logger\|os_log"
  Sources/Data/Backup` finds nothing.
- Covers: R1, R2, R3, R4, R5, R7, R8, R9, R10, R11, R12, R15 (service part); A1, A3 to A8, A10.

### T3. Password rule, hint, strings and docs (frontend)

- Goal: 2.5, the catalog and `gui.md`.
- Files: `Sources/Store/BackupModels.swift` (`ExportModel` only), `Sources/Views/ExportView.swift`,
  `Tests/BackupModelTests.swift` (`ExportModelTests` and `UnavailableBackupServiceTests.exportFails...`
  on passwords of 12 or more characters, F7, plus the A2 test), `Resources/Localizable.xcstrings`,
  `docs/design/gui.md`.
- Depends on: T1 (same files and owner). Runs in parallel with T2.
- Catalog: "Use at least 12 characters." / "Usa almeno 12 caratteri." (D3) and the two
  `BackupExportError` strings of 2.3, keys copied verbatim from T2 (the frontend owns the catalog, the
  backend never edits it).
- `gui.md`: Export section (12-character rule, permanent hint, the Failed state is a sheet state with
  Try Again and not an alert, size and encryption messages, Keychain failure aborts the export);
  "Contract with the data layer" (2.2); "Known gaps" (Release: Export real, Import disabled until #10).
- A2 test: `short-pass` twice disabled; `sample-backup-pass` twice enabled; `sample-backup-pass` and
  `sample-backup-paSS` mismatch shown and disabled; twelve spaces twice enabled; an 11-`Character`
  password with a combining accent (12 Unicode scalars) disabled.
- A5, sheet half (S1): an `ExportModel` over a service that throws `SerialStoreError.accessDenied`:
  the phase becomes `.failed` with the access-denied text of `SerialStoreError+Message.swift`, and
  `retry()` returns to `.entering` with the password kept. The test service is a small stub in the
  test file.
- Done when: tests green; every new key has `en` and `it` (`plutil -lint` on the catalog and a check
  that each new key has an `it` value).
- Covers: R6, R8 (sheet), R14, R15 (model part); A2, A5 (sheet).

### T4. Release wiring (frontend)

- Goal: 2.6.
- Files: `Sources/SerialManagerApp.swift`.
- Depends on: T1, T2 merged into `feature/encrypted-export`.
- Done when: Debug build and tests green; a local Release build succeeds
  (`xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`, F10).
- Covers: R13; A9 (by code review and T5).

### T5. Owner-run Release checklist (QA authors, frontend commits)

- Goal: D4: `docs/qa/encrypted-export-release-checklist.md`, same pattern as
  `docs/qa/license-form-release-checklist.md`, run only by Stefano on a signed Release build.
- Content (QA drafts, frontend commits it because QA is read-only): A9 (Export enabled with one license,
  Import disabled, Export disabled with none); hint visible and Export disabled under 12 characters;
  export of fake entries, summary counts, Show in Finder; `xxd file | head -4` shows `SMBACKUP` and the
  header of A1; Keychain prompt denied gives Export Failed with the access-denied text and no file;
  a second export to the same name replaces the file after the save panel's confirmation.
- Depends on: T4.
- Covers: R13 (A9), D4.

### Coverage

| Req | Tickets | Verification |
| --- | --- | --- |
| R1 | T2 | Header test, A1 |
| R2 | T2 | A1 round trip, A3, RFC 7914 vector; NFC pinned by literal `passwordBytes` and a direct `CCKeyDerivationPBKDF` key (B1) |
| R3 | T2 | A1, A4, A10 on raw JSON |
| R4 | T2 | A1, A4 summaries |
| R5 | T2 | A8 |
| R6 | T3 | A2 tests, review of the hint |
| R7 | T2, T3 | A6 tests, strings in the catalog |
| R8 | T2, T3 | A5 service test (error rethrown unchanged) and `ExportModel` Failed and Try Again test |
| R9 | T2 | A5, A6, write-error tests on existence and bytes |
| R10 | T2 | A7 |
| R11 | T2 | Actor (review) and `Thread.isMainThread` test |
| R12 | T2 | Review and grep of `Sources/Data/Backup` |
| R13 | T1, T4, T5 | Review, local Release build, owner checklist A9 |
| R14 | T3 | Review of `gui.md` and the catalog |
| R15 | T1 to T3 | CI green, no disabled test, grep for real-looking data |

## 4. Parallelism and shared files

```
T1 (frontend, small) ──> T3 (frontend) ──┐
        └──────────────> T2 (backend) ───┴──> T4 (frontend) ──> T5 (QA + frontend) ──> QA on the merge
```

T2 can start before T1 merges (new files only) and adds `nonisolated var isImportAvailable` once T1 is in.

| File | Owner | Also touched by | Rule |
| --- | --- | --- | --- |
| `Resources/Localizable.xcstrings` | frontend (T3) | none today | Single owner; backend sends its exact keys and never commits the file (S5). |
| `Sources/SerialManagerApp.swift` | frontend (T1, T4) | none today | One small hunk each. |
| `Sources/AppCommands.swift` | frontend (T1) | #7 (License menu, lines 26 to 32) | File menu hunk only; different hunk. |
| `docs/design/gui.md` | frontend (T3) | #5, #7 | Edit last, after a rebase. |
| `Tests/BackupModelTests.swift` | frontend (T1, T3) | none | Backend tests go in new files. |

## 5. Branch hygiene

- Before T1: `git fetch` and rebase `feature/encrypted-export` on `origin/main` if it moved.
- Before the `gui.md` and catalog edits of T3, and before the final merge: rebase again; if #5 or #7
  landed, resolve `gui.md` and `AppCommands.swift` by hand and re-run the tests. After any catalog
  merge, validate it with `plutil -lint`.
- The SPEC and this plan are committed in one `docs:` commit on `feature/encrypted-export` (Git agent,
  after the PLAN approval) before `feature/encrypted-export-backend` and `-frontend` fork from it, so
  neither ticket branch adds them (N3). Not committed by the Architect.

## 6. QA on the combined result

- `xcodebuild ... test` green on CI and locally; a local Release build green (until #13 adds it to CI).
- No test disabled, deleted or weakened: diff of `Tests/BackupModelTests.swift` shows only password
  values and the rewritten availability test.
- Grep for real-looking data in the diff (serial-like strings other than `FAKE-...`, real emails, real
  product names).
- Review R11 and R12 in `Sources/Data/Backup`; confirm import in the real service still throws
  `NotAvailable` and the File menu wiring matches A9.
- T5 checklist prepared for Stefano.
