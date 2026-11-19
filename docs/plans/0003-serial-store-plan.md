# Plan: Keychain serial store behind a protocol (ticket #3)

- Plan version: v2 (v1 approved by the Reviewer on 2026-11-19; v2 records Q1 = A per D5 and folds in review
  items S2 to S6, N1, N2)
- Date: 2026-11-19
- Input: `docs/specs/0003-serial-store.md` v2 (approved by Stefano on 2026-11-19), `docs/adr/0001-storage.md`,
  `Sources/Contract/LicenseContract.swift`, baseline `61dd579`
- Author: Architect
- Status: approved (PLAN review APPROVED, 2026-11-19)

## 1. Findings that shape the plan

### F1. Keychain implementation for R7 (sources retrieved 2026-11-19 from developer.apple.com, JSON doc API)

- `kSecUseDataProtectionKeychain` (macOS 10.15+): "Set the value for this key to `true` [...] when accessing a
  macOS keychain item that behaves like an iOS keychain item. For example, use the data protection key when
  adding, searching for, or deleting an item to which the `kSecAttrAccessible` or `kSecAttrAccessGroup`
  attributes apply." and "Use `kSecUseDataProtectionKeychain` to get the iOS behavior without synchronization."
  https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (macOS 10.9+): "Items with this attribute do not migrate to a
  new device." https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
- `kSecAttrSynchronizable` (macOS 10.9+): "If the key is not supplied, or has a value of `kCFBooleanFalse`,
  then no synchronizable items are added or returned."
  https://developer.apple.com/documentation/security/ksecattrsynchronizable
- TN3137 "On Mac keychain APIs and implementations" (revision 2026-09-24):
  - SecItem "defaults to targeting the file-based keychain. To target the data protection keychain, set the
    `kSecUseDataProtectionKeychain` attribute or the `kSecAttrSynchronizable` attribute to true."
  - "The file-based keychain is on the road to deprecation." and "Default to targeting the data protection
    keychain".
  - "macOS builds the list of data protection keychain access groups available to your program from its code
    signing entitlements. [...] These entitlements must be authorized by a provisioning profile."
  - "The keychain support in the `security` command-line tool is primarily focused on the file-based keychain."
    Keychain Access shows data protection password items under "Local Items" (or "iCloud").
  https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- `errSecMissingEntitlement`: the app's access groups come from `keychain-access-groups`, the application
  identifier (`com.apple.application-identifier` on macOS) and `com.apple.security.application-groups`.
  https://developer.apple.com/documentation/security/errsecmissingentitlement
- Access groups: "Xcode automatically prefixes the bundle ID with your team ID [...] and stores the combined
  string as the app ID. The system recognizes this app ID as the name of your app's default keychain access
  group". https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

Conclusion: only the data protection keychain honours a `ThisDeviceOnly` accessibility class, which is the
attribute that makes an item device-local in the sense of D4. Item attributes for R6 and R7:

| Key | Value |
|-----|-------|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | injected service, default `it.stefer.SerialManager` |
| `kSecAttrAccount` | `uuid.uuidString` |
| `kSecUseDataProtectionKeychain` | `true` (every call: add, update, copy, delete) |
| `kSecAttrSynchronizable` | `false` (explicit, every call) |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (add only) |
| `kSecValueData` | `Data(serial.utf8)` (add and update only) |

No `kSecAttrAccessGroup`: the item lands in the app's default (private) access group.

### F2. Current signing cannot use the data protection keychain (observed + inferred)

Observed on 2026-11-19 in this worktree (baseline `61dd579`, Tuist 4.218.1):
- The generated project sets `CODE_SIGN_IDENTITY = "-"` at target level, Debug and Release, both targets
  (Tuist default), so `DEVELOPMENT_TEAM` in `Project.swift` is not used for the signature.
- `codesign -dvv` on the Debug app: `Signature=adhoc`, `TeamIdentifier=not set`; entitlements contain only
  `com.apple.security.get-task-allow`; no `embedded.provisionprofile`.
- The Mac has a valid Apple Development identity for the team.

Inferred from TN3137 and `errSecMissingEntitlement` (not tested, because a real test would register an App ID
and a profile on Stefano's developer account): an ad-hoc signed app has no application identifier and no
access group, so `SecItemAdd` with `kSecUseDataProtectionKeychain` is expected to fail with
`errSecMissingEntitlement` (-34018).

Using the data protection keychain therefore needs, in `Project.swift`: a real development signing identity
(`CODE_SIGN_IDENTITY = "Apple Development"` for the app target) and an entitlement that requires a
provisioning profile (`keychain-access-groups = ["$(AppIdentifierPrefix)it.stefer.SerialManager"]`, the
"Keychain Sharing" capability, listing only the app's own group). Tuist 4.218.1 supports this through
`Target.entitlements: .dictionary([...])` (checked in the installed `ProjectDescription.swiftinterface`).
Consequences: `xcodebuild` must create or fetch the profile (`-allowProvisioningUpdates` the first time, or
one build from Xcode), the CLAUDE.md commands may need that flag, and CI (#12) must build with signing
disabled.

### F3. Smoke-check inspection

Per TN3137 the `security` command-line tool targets the file-based keychain, so it is not a reliable
inspector for data protection items. Inspection is done by (1) the harness printing what
`SecItemCopyMatching` returns for the smoke service (`kSecMatchLimitAll`, attributes only, never data), and
(2) a visual check in Keychain Access, "Local Items", searching for the smoke service (SPEC v2).

## 2. Decision Q1 (resolved)

Stefano chose the data protection keychain on 2026-11-19 (SPEC v2, D5): Apple Development signing on team
T7H24G7BFW, `keychain-access-groups` entitlement, App ID and development profile registered by Xcode. D5
covers the App ID and profile registration, so T1 needs no further approval. Consequences: signing change in
`Project.swift` (possible conflict with #2, section 6), CLAUDE.md commands possibly gaining
`-allowProvisioningUpdates`, CI (#12) building with signing disabled.

## 3. Design (fixed by this plan)

### 3.1 Files

| File | Content |
|------|---------|
| `Sources/Data/Serials/SerialStore.swift` | `SerialStore` protocol, `SerialStoreError` |
| `Sources/Data/Serials/KeychainSerialStore.swift` | Keychain implementation, query builder, status mapping |
| `Sources/Data/Serials/KeychainClient.swift` | Thin `Sendable` seam over the four SecItem functions, `.live` value |
| `Sources/Fakes/InMemorySerialStore.swift` | In-memory fake (next to the existing fakes, used by #4 tests) |
| `Sources/Support/KeychainSmokeCheck.swift` | `#if DEBUG` smoke harness (D2) |
| `Sources/SerialManagerApp.swift` | 3-line `#if DEBUG` hook that runs the harness and exits (T5) |
| `Tests/SerialStoreTests.swift` | Fake behaviour (A1 to A5, A7) |
| `Tests/KeychainSerialStoreTests.swift` | Mapping, query attributes and save/read/delete flow over a fake `KeychainClient` |
| `Project.swift` | Signing identity and entitlement (T1) |
| `docs/adr/0003-keychain-implementation.md` | Records F1, F2 and D5 (T6) |

### 3.2 Protocol (R1)

```swift
protocol SerialStore: Sendable {
    /// Stores `serial` for `id`, replacing any existing value. The value is stored as given.
    func save(_ serial: String, for id: UUID) async throws
    /// Returns nil when no item exists for `id`.
    func serial(for id: UUID) async throws -> String?
    /// Succeeds when no item exists for `id`.
    func deleteSerial(for id: UUID) async throws
}
```

`async throws` matches `LicenseRepository`, lets the fake be an actor like `InMemoryLicenseRepository`, and
keeps blocking SecItem calls off the main actor (Swift 6.0 language mode: a nonisolated `async` function runs
on the global executor). `Mutex` (Synchronization) is macOS 15+, so a sync API would need a lock; not chosen.

### 3.3 Errors (R8, R9)

```swift
enum SerialStoreError: Error, Equatable, Sendable {
    case accessDenied            // user or system refused access
    case undecodableData         // item data missing or not valid UTF-8
    case unexpected(status: OSStatus)
}
```

Mapping `SerialStoreError(status:)`, a pure function used only for non-success statuses:

| Status | Case |
|--------|------|
| `errSecAuthFailed` (-25293), `errSecInteractionNotAllowed` (-25308), `errSecUserCanceled` (-128), `errSecNoAccessForItem` (-25243) | `.accessDenied` |
| `errSecMissingEntitlement` (-34018) | `.unexpected(status:)` (a build or signing defect, not a user refusal) |
| `errSecDecode` (-26275) | `.undecodableData` |
| anything else | `.unexpected(status:)` |

`errSecItemNotFound` never reaches the mapper from read or delete: the operations handle it first (read
returns nil, delete returns). The cases carry no serial and no query; no `print`, `Logger` or
`CustomStringConvertible` in this code touches the value (R9).

### 3.4 Keychain implementation (R2 to R8)

```swift
struct KeychainSerialStore: SerialStore {
    static let defaultService = Bundle.main.bundleIdentifier ?? "it.stefer.SerialManager"
    init(service: String = Self.defaultService, client: KeychainClient = .live)
}

struct KeychainClient: Sendable {
    var add: @Sendable (CFDictionary) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var copyMatching: @Sendable (CFDictionary) -> (OSStatus, CFTypeRef?)
    var delete: @Sendable (CFDictionary) -> OSStatus
    static let live: KeychainClient   // wraps SecItemAdd, SecItemUpdate, SecItemCopyMatching, SecItemDelete
}
```

- One private `baseQuery(for:)` builds class, service, account, data protection flag and
  `synchronizable = false`, shared by all four calls, so a flag can never differ between calls.
- `save`: `update(baseQuery, [kSecValueData: data])`; on `errSecItemNotFound` → `add(baseQuery + data +
  accessible)`; if `add` returns `errSecDuplicateItem` (a concurrent save won) → `update` once more. Any other
  status → mapped error. Result: exactly one item per UUID (R2). Known edge (N2): if that second `update`
  returns `errSecItemNotFound` because a concurrent delete removed the item in between, save throws
  `.unexpected(status: -25300)`. Accepted: the consumer (#4) serialises its own operations per license, and
  the error is surfaced, not swallowed. Document it in a comment on `save`.
- `serial(for:)`: `copyMatching(baseQuery + kSecReturnData + kSecMatchLimitOne)`; `errSecItemNotFound` → nil;
  success with data that is not `Data` or not UTF-8 → `.undecodableData`; other → mapped.
- `deleteSerial(for:)`: `delete(baseQuery)`; `errSecSuccess` or `errSecItemNotFound` → return (D1).
- No trimming or validation (R5).
- `KeychainClient` exists so the whole flow is unit-tested with a dictionary-backed client. Tests never use
  `.live` and never construct `KeychainSerialStore()` with the default client (R11). Reviewer greps for
  `.live` and `KeychainSerialStore(` in `Tests/`.

### 3.5 Fake (R10)

`actor InMemorySerialStore: SerialStore` with `init(serials: [UUID: String] = [:], failure: (any Error)? = nil)`,
`setFailure(_:)`, and `var itemCount: Int` (for A1). Same observable behaviour as R2 to R5; when a failure is
set, save, read and delete all throw it (A7). Unlike `InMemoryLicenseRepository.store(serial:)` it stores
empty strings as given (empty-serial policy is #4's).

### 3.6 Smoke harness (D2)

- `KeychainSmokeCheck` (`#if DEBUG`): runs against `KeychainSerialStore(service: "it.stefer.SerialManager.smoke")`
  with the fixed UUID `00000000-0000-4000-8000-000000000003` and fake values `SMOKE-AAAA-1111`,
  `SMOKE-BBBB-2222`. Steps, each printed as `PASS`/`FAIL <step>`: delete (clean start), save A, inspect,
  read = A, save B, inspect, read = B, delete, inspect, read = nil, delete again (no error). "Inspect" runs
  `SecItemCopyMatching` with the same base query and `kSecMatchLimitAll` + `kSecReturnAttributes` and prints
  the item count, service, account, `sync`, `pdmn` (accessibility) and `agrp` (access group). It never prints
  data. Exit code 0 when every step passes, 1 otherwise; it always ends with a delete so no item is left.
- Inspect with `kSecMatchLimitAll` returns `errSecItemNotFound` when no item matches: treat that as count 0,
  not as a failure (S5). A failed "read = A/B" step prints only `FAIL <step>`, never the value read (S5, R9).
- Hook: `SerialManagerApp.init()` checks `CommandLine.arguments.contains("--keychain-smoke-check")` in
  `#if DEBUG` and calls `KeychainSmokeCheck.runAndExit()`, which blocks on a detached task and calls `exit`.
  It must run inside the signed app process because the entitlement belongs to the app.
- Deadlock assumption (S4): blocking the main thread on a detached task is safe only while the target does
  not set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or `NonisolatedNonsendingByDefault` (neither is set
  today: SWIFT_VERSION 6.0), because `KeychainSerialStore`'s nonisolated async methods then run on the global
  executor. State this assumption in a comment in `KeychainSmokeCheck.swift`.
- Not a test, not in any scheme or test plan (R11). Release builds do not contain it (checked in T4, S2).
- QA runs: `<DerivedData>/Build/Products/Debug/SerialManager.app/Contents/MacOS/SerialManager --keychain-smoke-check`.

## 4. Tickets

| Id | Title | Owner | Depends on | Parallel with |
|----|-------|-------|------------|---------------|
| T1 | Signing spike | backend | none (D5 covers App ID/profile registration) | T2, T3 |
| T2 | Protocol, error type, fake + fake tests | backend | none | T1 |
| T3 | Keychain implementation + client seam + mapping/flow tests | backend | T2 (protocol/error file) | T1 |
| T4 | Full build and test, data and scope check | backend | T1, T2, T3, T5 (Release check) | none |
| T5 | Smoke harness + manual smoke check | backend builds, qa runs | T1, T3 | T6 |
| T6 | ADR 0003 on the keychain implementation | backend (Architect drafts text on request) | none | T2 to T5 |
| T7 | Combined QA and review | qa, code-reviewer | T4, T5, T6 | none |

One backend developer can do T2 then T3 back to back; T1 can run first or in parallel. Frontend has no work
in this ticket (R12): confirmed.

### T1. Signing spike

- SPEC: R7, R13. Files: `Project.swift` only (then `tuist generate --no-open`).
- Change, app target only: `"CODE_SIGN_IDENTITY": "Apple Development"` in the target settings and
  `entitlements: .dictionary(["keychain-access-groups": ["$(AppIdentifierPrefix)it.stefer.SerialManager"]])`.
  Test target unchanged.
- Expected outcome and verification (backend, recorded in the ticket):
  1. `xcodebuild ... -allowProvisioningUpdates build` succeeds (first time only; App ID and profile creation
     on the team is covered by D5);
  2. `codesign -d --entitlements - <app>` shows `com.apple.application-identifier` =
     `T7H24G7BFW.it.stefer.SerialManager` and the `keychain-access-groups` entry;
  3. `<app>/Contents/embedded.provisionprofile` exists;
  4. plain `xcodebuild ... build` and `... test` (CLAUDE.md commands) pass afterwards; if they need
     `-allowProvisioningUpdates`, update the CLAUDE.md Commands block in the same commit. This step is
     mandatory (S6): `TEST_HOST` is the app, so after T1 the ad-hoc signed test bundle loads into a
     team-signed host. That works while hardened runtime is off (not set today); a failing `test` here means
     the host/bundle signing combination needs fixing before T2 and T3 tests can run.
  The actual `SecItemAdd` check happens in T5 (the harness is the only code allowed to touch the real
  Keychain).
- Risk: conflict with #2 (section 6). Commit alone: `chore(project): sign app with development identity for data protection keychain`.

### T2. `SerialStore` protocol, error and in-memory fake

- SPEC: R1, R2 to R5 and R10 (fake side), R9, R11, R12. Files: `Sources/Data/Serials/SerialStore.swift`,
  `Sources/Fakes/InMemorySerialStore.swift`, `Tests/SerialStoreTests.swift`.
- Outcome: design 3.2, 3.3 (type only), 3.5.
- Verification: Swift Testing tests on the fake for A1 (value replaced, `itemCount == 1`), A2, A3, A4, A5
  (`"  TÉST-ÄÖÜ-✓  "` round-trips exactly, plus an empty string round-trips), A7 (failure thrown by all three
  operations, and `setFailure(nil)` restores behaviour).

### T3. Keychain implementation

- SPEC: R2 to R9, R11. Files: `Sources/Data/Serials/KeychainSerialStore.swift`,
  `Sources/Data/Serials/KeychainClient.swift`, `Tests/KeychainSerialStoreTests.swift`.
- Outcome: design 3.3 mapping and 3.4.
- Verification, all with a dictionary-backed `KeychainClient` (never `.live`):
  - A6: `-25293`, `-25308`, `-128`, `-25243` → `.accessDenied`; `-26275` → `.undecodableData`; `-34018` and
    an arbitrary status such as `-99999` → `.unexpected(status:)` with that status.
  - Query: every call receives class, service, account = `uuid.uuidString`, `synchronizable = false` and
    the data protection flag; `add` receives `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; injected
    service is used.
  - Flow: save twice → one entry with the second value (update path); save when the client returns
    `errSecDuplicateItem` on add → falls back to update; read not-found → nil; read non-UTF-8 data →
    `.undecodableData`; delete not-found → no throw; any other status propagates as the mapped error.
  - R9: `String(describing:)` of each error case does not contain the sample serial.

### T4. Integration check

- SPEC: R12, R13. No new files.
- Verification:
  - CLAUDE.md build and test commands pass.
  - R12 (S3): `grep -rln "SerialStore" Sources/` lists only files under `Sources/Data/Serials/`,
    `Sources/Fakes/InMemorySerialStore.swift` and `Sources/Support/KeychainSmokeCheck.swift` (this covers
    `Sources/Views`, `Sources/Store`, `Sources/ContentView.swift` and `Sources/AppCommands.swift`).
  - `git diff main -- Sources/Contract/LicenseContract.swift` is empty; `InMemoryLicenseRepository` and the
    GUI are unchanged.
  - Harness absent from Release (S2): `xcodebuild ... -configuration Release build` succeeds (this also
    proves Release still signs under D5) and
    `strings <Release app>/Contents/MacOS/SerialManager | grep -c keychain-smoke-check` prints `0`.
  - Only obviously fake values (`TEST-`, `SMOKE-`) in new code.

### T5. Smoke harness and manual smoke check (D2)

- SPEC: R6, R7, A8. Files: `Sources/Support/KeychainSmokeCheck.swift`, `Sources/SerialManagerApp.swift`
  (hook only).
- Outcome: design 3.6. Backend builds Debug and hands QA the exact command and the expected output.
- QA verification (manual, Debug build on Stefano's Mac): every step prints `PASS`, exit code 0; inspect
  shows count 1 after each save, count 0 after delete, service `it.stefer.SerialManager.smoke`, account
  `00000000-0000-4000-8000-000000000003`, `sync` 0, `pdmn` = `aku` (WhenUnlockedThisDeviceOnly) and
  `agrp` = `T7H24G7BFW.it.stefer.SerialManager`. Keychain Access, Local Items, shows no item for the smoke
  service after the run.
- Risk: touches `SerialManagerApp.swift`, which #4 rewires; the hook is a separate `#if DEBUG` line at the top
  of `init()` so the merge is trivial.

### T6. ADR 0003: keychain implementation

- SPEC: R7 (documented sources). File: `docs/adr/0003-keychain-implementation.md`.
- Content: F1 sources with retrieval date 2026-11-19, F2 observation, D5 and its consequences (signing,
  CI, `security` tool). Commit `docs: add ADR on keychain implementation`.

### T7. Combined QA and review

- QA: T5 manual check; run the CLAUDE.md test command and confirm the new suites ran and passed.
- Reviewer: R1 signatures as in 3.2; R8 mapping table; R9 no value in errors or logs; R11 no `.live` or
  default-client `KeychainSerialStore` in `Tests/`, harness not reachable from tests and absent from Release;
  R12 greps; R13 fake data only; Project.swift diff limited to T1.

## 5. Requirement → verification

| Req | Ticket | Method |
|-----|--------|--------|
| R1 | T2 | Review against 3.2; compiles under Swift 6 strict concurrency |
| R2 | T2, T3 | A1 on fake; save-twice and duplicate-fallback tests on fake client; A8 count 1 |
| R3 | T2, T3 | A2 on fake; read not-found test on fake client |
| R4 | T2, T3, T5 | A3, A4 on fake; delete not-found test; A8 "delete again" |
| R5 | T2 | A5 on fake (and empty string) |
| R6 | T3, T5 | Query attribute tests; A8 inspect (service, account) |
| R7 | T1, T3, T5, T6 | Query attribute tests; A8 `sync`/`pdmn`/`agrp`; ADR sources |
| R8 | T3 | A6 mapping tests; flow tests for not-found handling |
| R9 | T3, T7 | Description test; review |
| R10 | T2 | A7 on fake |
| R11 | T3, T5, T7 | Review greps; harness is not a test |
| R12 | T4, T7 | Greps; empty diff on `LicenseContract.swift` |
| R13 | T4, T7 | CLAUDE.md build and test; fake data check |

## 6. Risks and coordination

- **#2 conflict (Project.swift):** #2 (SwiftData model, worktree `feature/license-model`, no commits yet as of
  2026-11-19) may edit `Project.swift`. T1 touches only the app target's `settings` and adds `entitlements`;
  whichever merges second rebases. If #2 adds a SwiftData capability or other entitlements, both must end up in
  the same `entitlements` dictionary. The Lead should tell #2's owner.
- **#4 overlap (SerialManagerApp.swift):** T5 adds a `#if DEBUG` hook; #4 replaces the fake wiring in the same
  `init()`.
- **#12 CI:** CI must pass `CODE_SIGNING_ALLOWED=NO` (or equivalent); tests do not need the
  Keychain, so this is safe.
- **Developer account:** T1 creates an App ID and a macOS development profile on team T7H24G7BFW (approved
  by Stefano in D5).
- **Locked screen:** with `WhenUnlocked`, a read while the Mac is locked fails with
  `errSecInteractionNotAllowed` → `.accessDenied`. Acceptable: reads are user-driven.
