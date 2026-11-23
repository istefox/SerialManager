# SPEC: File attachments, search, filters and sorting (#18)

- Version: v1
- Status: awaiting Stefano's approval
- Ticket: #18 "File Attachments and Search" (tags: serial, gui)
- Baseline: `eef37ad` on `main`
- Depends on: nothing open. Builds on #5 (list and search), #6 (form), #7 (detail), #9 and #10 (backup).

## Context

Some vendors deliver a license not as a string but as a file the user double-clicks to apply
(`.lic`, `.key`, a signed plist, sometimes a PDF invoice carrying the key). Today SerialManager has
nowhere to put that file, so the one thing needed to reinstall the software lives outside the app and
outside the backup.

What exists today, read at `eef37ad`:

- `LicenseStore.visibleLicenses` filters on `productName` and `vendor` only, with
  `localizedStandardContains` on the whole trimmed query.
- `LicenseStore.sorted` is the only ordering: `productName` ascending with `localizedStandardCompare`,
  applied in `init`, `load` and `save`. There is no UI for order.
- The sidebar search prompt is "Name or vendor" (`LicenseListView`).
- `registeredName` exists on the model, the contract, the payload and both views since `8d7a003`,
  but nothing searches it.
- Storage follows ADR 0001: metadata in SwiftData (`Licenses.store`), serials in the Keychain keyed by
  license UUID, and "the SwiftData store never contains a serial". ADR 0003 fixes the Keychain
  attributes: data protection keychain, `kSecAttrService` the bundle identifier **and injectable**,
  `kSecAttrAccount` the UUID string, `WhenUnlockedThisDeviceOnly`, `Synchronizable` false.
- The backup is format version 1 (ADR 0002), with a 64 MiB cap on the whole file
  (`BackupFormat.maxBackupFileSize = 67_108_864`) enforced at export and at import, and
  `BackupExportError.fileTooLarge` already exists for an over-size export.
- `Project.swift` declares one bundle identifier, `it.stefer.SerialManager`, for every configuration.
  **Debug and Release therefore share the same Application Support folder and the same Keychain
  service.** This drives R9 and R13.
- The app is **not sandboxed** (no `app-sandbox` entitlement), so it can read a file the user picks and
  write into its own Application Support folder without security-scoped bookmarks.

## Decisions (Stefano, 2026-11-23)

- **D1, attachments at rest: encrypted copies, key in the Keychain.** The app copies the picked file
  into its own folder and encrypts it with a key of its own. Rationale: ADR 0001 keeps serials out of
  the store file because they are the sensitive value, and a license file **is** a serial in file form.
  A plain copy would put that value back on disk in clear text. Rejected: plain copies (would amend
  ADR 0001), and storing only a path to the original (breaks when the user moves the file, and the
  backup could never carry it).
- **D2, attachments go into the `.smbackup`.** A restore on a new Mac must rebuild the whole library,
  files included. That is the reason the app has a backup at all (ADR 0001, consequence 5).
- **D3, limits: several attachments per license, 5 MB per file, 20 MB per license.** Stated in bytes to
  remove any ambiguity, decimal like the Finder: **5,000,000 bytes per file, 20,000,000 bytes per
  license**, measured on the plaintext.
- **D4, the backup cap stays 64 MiB, with a library-wide total instead.** `maxBackupFileSize` is not
  raised. The app refuses a new attachment once the library's total would exceed **40,000,000 bytes**
  of plaintext attachments, with a message that says so. Arithmetic behind the number: base64 inflates
  by 4/3, so 40,000,000 bytes become 53,333,336 bytes of payload, inside the 67,108,864-byte cap with
  about 13 MB left for license metadata, far more than any realistic library needs. Rejected: raising
  the cap to 256 MiB (export and import hold the whole file in memory), and leaving the cap alone with
  no total (the export would start failing and the only remedy would be deleting license files in
  order to be able to back up).

## Decisions taken in this spec (open to Stefano's review)

- **D5, the format version goes to 2.** ADR 0002 section 7 would let `attachments` in as an optional
  payload key at version 1, but the same section says an older app then "ignores the key and loses it
  if it re-exports the data". Silently losing a license file is worse than a clear refusal, so the clear
  header version becomes 2: a build made before this change fails the file with `unsupportedVersion`
  ("This backup was made with a newer version of SerialManager.") instead of dropping the attachments.
  Export always writes version 2; import keeps reading version 1, where a license simply has no
  attachments.
- **D6, attachments are a separate SwiftData entity, not a relationship on `License`.** A new
  `@Model AttachmentRecord` carries `licenseID: UUID` and no SwiftData relationship, the same
  keyed-by-UUID shape the Keychain already uses for serials. Reason: `License` holds its invariants
  through `private(set)` properties and three throwing write paths (`init`, `update`, `restore`; SPEC
  `license-model.md` R4), and a to-many relationship would open a fourth write path and a harder
  migration. **`License` is not modified by this ticket.**
- **D7, one library-wide encryption key.** 32 random bytes, stored as a generic password in the
  Keychain with the same attributes ADR 0003 fixes for serials (data protection keychain,
  `WhenUnlockedThisDeviceOnly`, `Synchronizable` false, service injectable) under a fixed account name
  distinct from any UUID, for example `attachment-key`. Encryption is AES-256-GCM through CryptoKit,
  as the backup already uses. Not per-file keys: one key is enough for a single-user local app and
  keeps the failure modes countable.
- **D8, "date of entry" is `createdAt`, "date of modification" is `updatedAt`.** Not `purchaseDate`,
  which is a property of the purchase and is often unset.
- **D9, adding or removing an attachment bumps `updatedAt`** of its license, so "sort by date
  modified" reflects it and the detail view's "Modified" footer stays truthful. **An import does not**
  (R24): SPEC 0010 D3 keeps a backup's dates exactly as written.
- **D10, the default order stays product name ascending.** The existing test
  `loadSortsByNameIgnoringCase` and every user habit assume it. The chosen order persists in
  `@AppStorage`.
- **D11, search stays whole-query substring matching** (`localizedStandardContains` on the trimmed
  query), extended to more fields. Splitting the query into tokens matched with AND is a different
  feature and is out of scope: it would change the meaning of every query that works today.
- **D12, Replace on import merges attachments, it never deletes one.** ADR 0002 already promises that
  "an import never deletes a Keychain item". The same promise applies here: with
  `ConflictPolicy.replace`, an attachment of the backup whose id is absent locally is added, an id
  already present locally is left alone, and a local attachment absent from the backup is kept.
  Consequence, to be stated in the user guide: after a Replace a license can hold more attachments
  than either side had alone, and the library total of D4 can be exceeded. An import is never refused
  for being over a limit (R24): a restore must not lose data.
- **D13, attachments are applied on Save, in the new form and in the edit form alike** (R15, R16).
  One rule for both, so Cancel always means "nothing happened".
- **D14, opening an attachment goes through a decrypted temporary copy** (R18). The encrypted blob is
  never handed to another app.
- **No "Show in Finder".** With encrypted storage the only thing it could reveal is a temporary copy
  that disappears at quit, which is misleading. The detail view offers Open and Save a Copy… only.

## Scope

In scope:

1. **Sorting**, R1 to R3: six orders, a picker in the sidebar toolbar, persisted.
2. **Search and filters**, R4 to R7: more searched fields, a field scope picker, updated prompt and
   empty state.
3. **Attachments**, R8 to R28: data layer, encryption, form, detail, search by file name, backup
   format version 2, strings, fixtures, documentation.

Out of scope, to be said explicitly in the handoff:

- Token search (D11), regular expressions, search in the **content** of an attachment, and search in a
  serial's characters. A serial is never matched by search, today or after this ticket.
- Drag and drop of a file onto a license row or the detail pane. Only a file picker.
- Thumbnails, Quick Look previews, inline PDF rendering, "Show in Finder".
- Editing, renaming or versioning an attachment. An attachment is added or removed, never changed.
- Raising `BackupFormat.maxBackupFileSize`, and streaming export or import. Both still hold the whole
  file in memory, as today.
- Any new export error case: `fileTooLarge` already exists and stays the backstop.
- Any change to `License`, to `SerialStore`, or to the Keychain storage of serials.
- Sorting or filtering commands in the main menu bar. The pickers live in the sidebar toolbar only.
- Saved or compound filters, and filtering by date range.
- iCloud, sync, and any way of getting a file out other than Open and Save a Copy….

## Requirements

### Sorting

- **R1, the six orders.** The list can be ordered by: product name ascending, product name descending,
  date added newest first, date added oldest first, date modified newest first, date modified oldest
  first. Name comparisons use `localizedStandardCompare`, so "iTunes" and "Itunes" sort together and
  "Item 2" precedes "Item 10".
- **R2, a stable total order.** Every order ends in a tie-breaker chain whose last term is unique per
  license, so two licenses never swap places between two renderings of the same data: the date orders
  fall back to product name then to the license `id`, the name orders fall back to `id`.
- **R3, the chosen order persists.** Stored in `@AppStorage`, it survives a quit and relaunch and
  defaults to product name ascending (D10). A stored value the app does not recognise falls back to
  the default without a crash. The picker sits in the sidebar toolbar, shows which order is active,
  and reorders the list without clearing the search text or the selection: the selected license stays
  selected and stays visible.

### Search and filters

- **R4, the searched fields.** With the scope set to all fields, the query matches any of
  `productName`, `vendor`, `registeredName`, `registeredEmail`, `version`, `notes`, and the **file name
  of any attachment** of that license. Case- and diacritic-insensitive (`localizedStandardContains`),
  whole query (D11). A whitespace-only query shows every license, as today.
- **R5, the field scope.** A picker offers: All Fields (default), Product Name, Vendor, Registered Name,
  Attachment Name, Notes. With a scope other than All Fields the query matches that field only. The
  scope is **not** persisted across launches: it resets to All Fields, so a search never silently
  returns nothing because of a filter set days ago.
- **R6, the prompt and the empty state.** The sidebar search prompt names what is being searched and
  changes with the scope. When a query matches nothing the sidebar shows the existing
  `ContentUnavailableView.search` state; when a scope other than All Fields is active, that state also
  says which field was searched and offers a way back to All Fields.
- **R7, no serial is ever searched.** No scope and no query reaches the Keychain. Searching is a pure
  function of what the store already holds in memory.

### Attachments: data layer

- **R8, the metadata entity.** `AttachmentRecord` is a new `@Model` in the same `ModelContainer` as
  `License`, with: `id: UUID` (unique), `licenseID: UUID`, `fileName: String` (the original name as the
  user picked it, never blank), `byteCount: Int` (the plaintext size), `contentType: String?` (the
  UTType identifier when known), `addedAt: Date`. No SwiftData relationship (D6).
- **R9, the bytes, in an injectable directory.** Each attachment's bytes live in one file at
  `<attachments directory>/<attachment id>`, encrypted with AES-256-GCM under the library key. The file
  name on disk is the attachment's UUID, never the user's file name: the original name is metadata, and
  a folder listing must not leak which software the owner owns. The default directory is
  `Application Support/<LicenseLibrary.folderName>/Attachments`, and **the directory is a constructor
  parameter with that default**, the way `KeychainSerialStore.service` is injectable (ADR 0003,
  decision 2): Debug and Release share one bundle identifier, so no test and no preview may ever be
  able to reach the real folder.
- **R10, the key, created only when it is safe to.** The key is read from the Keychain. A new key is
  generated and stored **only when the Keychain reports that no key item exists and the library holds
  no attachment**. Access denied, an undecodable item, or any other Keychain failure is surfaced as an
  error and never produces a new key: silently replacing a lost key would make every stored file
  permanently undecryptable while the app looked healthy. Key access goes behind a protocol with an
  in-memory fake, like `SerialStore` (ADR 0001, consequence 3): **no test touches the real Keychain.**
- **R11, the repository contract.** `LicenseRepository` gains: add an attachment (bytes, file name,
  content type) to a license; remove an attachment by id; read an attachment's bytes by id.
  `LicenseSummary` gains `attachments: [AttachmentSummary]`, ordered by `addedAt` then `fileName`,
  where `AttachmentSummary` carries id, file name, byte count, content type and `addedAt` and
  **never the bytes**: the sidebar and the detail view must render a license without decrypting
  anything. `importLicense` gains a parameter carrying the attachments **with** their bytes, since
  `LicenseSummary` deliberately has none; the signature change is part of this ticket.
- **R12, one attachment is one unit.** Adding writes the encrypted file first, then inserts the
  metadata and saves. A failure after the file was written deletes that file before the error is
  thrown, following the compensation pattern already in `SwiftDataLicenseRepository`. The invariant:
  **no metadata row ever points at a missing file.** The reverse residue, a file with no row, is
  invisible to the user and is left alone (R13).
- **R13, no orphans, and no sweep.** Deleting a license deletes every attachment row and every one of
  its files. Removing one attachment deletes its row and its file. A row whose file is missing is shown
  in the detail view as an unreadable attachment and can be removed, exactly as a license with a
  missing Keychain item is handled today. **The app must not delete files that have no matching row.**
  A Debug build, a test host or a store that failed to open all resolve the same bundle identifier and
  therefore the same real folder, and a sweep run against a zero-row or in-memory container would
  delete every real attachment the owner has. An orphan file wastes a few bytes and harms nothing;
  that trade is deliberate.
- **R14, the existing library still opens.** A `Licenses.store` written by `eef37ad` opens after this
  change with every license and every serial intact, and its licenses show zero attachments. Adding an
  entity to the container is a lightweight migration and must be verified against a real store file
  copied from the previous build, the way `8d7a003` verified `registeredName`.
- **R15, one license is one unit, extended.** `importLicense` keeps its guarantee: on failure the call
  leaves no change of its own beyond the documented compensation residue, now including attachment
  files written during that same call.

### Attachments: interface

- **R16, adding to an existing license.** The edit form has an Attachments section listing the current
  attachments with name and size, a button to add a file through the system file picker (any file
  type), and a way to remove one. Per D13 nothing is written until Save: picked files are held in
  memory, removals are marked, and Cancel leaves the library exactly as it was. Over a limit of D3 or
  D4 the app refuses the file at the moment it is picked, names the file and says which limit was hit
  and what it is; nothing is added. On Save, if attachment *k* of *n* fails to write, the licence's own
  fields are still saved, the attachments written before *k* stay, the rest are not written, and the
  error names the file that failed and how many were not added.
- **R17, adding to a new license.** Same rule (D13): picked files are held in memory until Save, then
  written once the license id exists. They count toward `hasChanges`, so Cancel with a pending
  attachment raises the existing "Discard changes?" confirmation and discarding writes nothing. Both
  limits of D3 and the total of D4 apply to the pending set.
- **R18, the detail view.** A read-only Attachments section lists each attachment with its name and
  size, and offers Open and Save a Copy… on each. The section is absent when the license has no
  attachment, like the existing Notes section.
- **R19, opening a file, the point of the ticket.** Open decrypts the attachment into a temporary copy
  under the app's temporary directory, keeping the original file name so the receiving app sees the
  extension it expects, then asks the system to open it. The stored encrypted copy is never passed to
  another app and is never modified by it. Temporary copies are deleted when the app quits and,
  defensively, at the next launch, which is safe because that directory belongs only to this feature.
  **Known limit, to state in the user guide:** a vendor installer may move, consume or alter the
  temporary copy. That is harmless, the stored copy is untouched, but the user must not expect to find
  the opened file afterwards.
- **R20, Save a Copy…** writes a decrypted copy where the user chooses, with the original file name.
- **R21, errors are explicit.** A failure to read the key, to decrypt, or to read a missing file
  produces a message the user can act on, never a silent empty file and never a crash. No message, log
  or error ever contains the key, the plaintext bytes or a serial.

### Attachments: backup

- **R22, format version 2.** The clear header version becomes 2 (D5). Export always writes 2. Import
  accepts 1 and 2; a version above 2 keeps failing with `unsupportedVersion` before any key is derived,
  as today. ADR 0002 is amended with the version 2 payload and a section 7 note explaining why an added
  key did not keep the format at version 1 this time.
- **R23, the payload.** Each license entry gains an `attachments` array whose elements carry the
  attachment id, file name, content type, plaintext byte count, `addedAt`, and the bytes as base64.
  The array is always written, `[]` when there is none. A version 1 file, or a version 2 entry without
  the key, imports as a license with no attachments; unknown keys are still ignored. An entry whose
  base64 does not decode, or whose decoded length does not match `byteCount`, makes the file
  `corruptedFile`, consistent with how a malformed required key is treated today.
- **R24, the size budget.** The 64 MiB cap stays (D4). The library total of 40,000,000 plaintext bytes
  is enforced when an attachment is added, so a normal library can never produce an over-size backup.
  `BackupExportError.fileTooLarge` stays as the backstop for the cases the total cannot prevent, in
  particular a library grown past it by an import (D12); its message is extended to say that
  attachments are the usual cause.
- **R25, import conflicts.** Skip leaves the local license, its serial and its attachments untouched.
  Replace replaces the metadata and **merges** attachments by id (D12): an id absent locally is added
  with its bytes, an id already present is left alone, a local attachment absent from the backup is
  kept. An import never deletes an attachment or its file, never refuses an attachment for being over a
  limit, and **never bumps `updatedAt`**: the dates come from the backup (SPEC 0010 D3, and D9 here).
- **R26, the export summary.** `ExportSummary` reports how many attachments were written, alongside the
  existing license and missing-serial counts, and the export sheet shows it.

### Strings, fixtures and documentation

- **R27, strings.** Every new user-facing string is in `Resources/Localizable.xcstrings` with an
  English and an Italian value: the six order names, the scope names, the search prompts, the limit
  messages, the attachment row labels and the error messages.
- **R28, fixtures stay fake, and tests stay off the real folder.** The repository is public. Sample
  data, previews and tests use obviously fake attachments: tiny files named like `Sample-Pro.lic` with
  placeholder content such as `FAKE LICENSE FILE, NOT A REAL KEY`. No real license file, no real
  serial, no personal name or address, not even in a preview. Every test injects its own attachments
  directory (R9) and its own key store (R10).
- **R29, documentation.** A new ADR records the attachment storage decision (D1, D6, D7) and what it
  adds to ADR 0001. ADR 0002 is amended for version 2 and the size budget (R22, R23, R24, R25).
  `docs/design/gui.md` covers the sort picker, the scope picker and the two attachment sections. The
  README user guide (SPEC 0011) covers adding, opening, the limits of D3 and D4, and the limit of R19.
  `PROJECT_BRIEF.md` "Scope" and "Status" record the milestone.

## Acceptance criteria

Split in two, because QA cannot reliably drive a system file picker: everything provable without the
GUI must be proved by a test.

### A. Automated, Swift Testing, no real Keychain and no real Application Support folder

- **A1.** For a fixed set of licenses each of the six orders of R1 produces the expected sequence,
  including a case-insensitive name pair and two licenses sharing a `createdAt`: repeated calls give
  the identical order (R2).
- **A2.** An unrecognised stored order value falls back to product name ascending (R3).
- **A3.** With scope All Fields a query matches on each of the seven fields of R4 in turn, including an
  attachment file name, and matches nothing it should not. Case and diacritics are ignored. A
  whitespace-only query returns every license.
- **A4.** With each scope of R5, a query matching only another field returns no license.
- **A5.** Adding an attachment through the real `SwiftDataLicenseRepository` (in-memory SwiftData
  container, in-memory serial store, in-memory key store, temporary attachments directory) creates one
  metadata row and one file, and the bytes on disk are **not** equal to the plaintext: it is actually
  encrypted (R9).
- **A6.** Reading that attachment back returns the original bytes exactly.
- **A7.** A file of 5,000,001 bytes is refused, nothing is written, and the error names the per-file
  limit. Files totalling 20,000,001 bytes on one license are refused at the file that crosses it, and
  everything added before it is still there. The same for the 40,000,000-byte library total across
  several licenses (D3, D4, R16).
- **A8.** A failure injected after the file is written leaves no metadata row **and** no file (R12).
- **A9.** Deleting a license deletes every attachment row and every file of that license (R13).
- **A10.** A metadata row whose file was removed behind the app's back surfaces as an unreadable
  attachment and can be removed, with no crash, and a file with no row is left in place (R13).
- **A11.** Adding and removing an attachment each bump the license's `updatedAt`; importing one does
  not (D9, R25).
- **A12.** The key store is read, not written, when a key already exists; a new key is generated only
  when the store reports not-found **and** no attachment exists; an access-denied answer throws and
  generates nothing (R10).
- **A13.** A round trip through the real `EncryptedBackupService`: export a library with attachments,
  import it into an empty library, and every attachment's file name, content type, byte count,
  `addedAt` and bytes come back identical, with `ExportSummary` reporting the right attachment count
  (R22, R23, R26).
- **A14.** A version 1 backup file still imports and its licenses have no attachments (R22).
- **A15.** A version 2 entry with malformed base64, and one whose decoded length disagrees with
  `byteCount`, both fail as `corruptedFile` (R23).
- **A16.** Import Skip changes no local attachment. Import Replace adds the backup's new attachment ids
  and keeps every local attachment, including one absent from the backup, and does so even when the
  result exceeds the library total (R25, D12).
- **A17.** A backup that would exceed 64 MiB fails with `fileTooLarge` and writes no file (R24).
- **A18.** No test reads or writes the real Keychain or the real Application Support folder, and no
  test file contains a plausible real serial or license file (R28).

### B. Manual, on a signed Release build, with obviously fake data, deleted at the end

- **B1, upgrade.** Launch the new build on the library written by the previous build: every license and
  every serial is there, and each license shows zero attachments (R14).
- **B2, existing license.** Add two files to an existing license, quit, relaunch: both are listed with
  the right names and sizes (R16).
- **B3, new license.** Create a license with two attachments in one go; both are there after Save.
  Repeat and press Cancel: the discard confirmation appears, and after discarding neither the license
  nor any file exists (R17).
- **B4, Cancel on an edit.** Add one file and remove another in the edit form, then Cancel: the license
  is exactly as it was (D13).
- **B5, open.** Open an attachment and the right application receives a file with the original name.
  After that application has had it, the attachment is still listed and still opens (R19).
- **B6, Save a Copy…** produces a usable file with the original name (R20).
- **B7, limits.** Picking a file over 5,000,000 bytes is refused with a message naming the limit, and
  nothing is added (R16).
- **B8, search.** A query on part of an attachment file name finds its license; the same query with the
  scope set to Product Name finds nothing, and the empty state says which field was searched
  (R4, R5, R6).
- **B9, sorting.** Each of the six orders reorders the sidebar correctly; the chosen order survives a
  quit and relaunch; changing it keeps the selection and the search text (R1, R3).
- **B10, at rest.** Open the `Attachments` folder in the Finder: files are named by UUID, and opening
  one in a text editor shows no readable license text and no product name (R9, D1).
- **B11, backup round trip.** Export with attachments, import the file into an empty library on the
  same Mac, and open an attachment from the restored license (R22, R23). Then try the same file on the
  previous build and confirm it refuses with the "newer version" message (D5).
- **B12, cleanup.** Delete the fake licenses from the app; the `Attachments` folder holds no file
  belonging to them (R13).

## Risks and open points for the developer

- **Attachments are the whole risk of this ticket.** Sorting and search touch `LicenseStore`,
  `LicenseListView` and tests only. Attachments touch the SwiftData schema, the Keychain, the file
  system, two views and the backup format. If the ticket has to be cut, ship sorting and search first:
  they stand alone and have no dependency on the rest.
- **The schema migration (R14) is the one failure that loses user data**, and it cannot be proved by a
  test against an in-memory container. Verify it against a real store file copied from the previous
  build before building anything on top of it.
- **Debug and Release share the bundle identifier**, hence the folder and the Keychain service. R9's
  injected directory and R13's refusal to sweep exist because of that. Do not "improve" either one.
- **ADR 0002 is being changed, not just extended.** Version 2 means the previous build refuses the new
  files. That is intended (D5) and must appear in the ADR, in the user guide and in the commit message.
- The 64 MiB cap is on the **encrypted file**, after base64. The 40,000,000-byte library total is what
  keeps a normal library inside it; an import can legitimately push a library past that total (D12),
  and `fileTooLarge` is the backstop for that case only.
- `EncryptedBackupService` is an actor on purpose, so PBKDF2 and AES-GCM stay off the main actor
  (project memory, `features/backup.md`). Base64 encoding of attachments must not undo that: no
  attachment encoding on the main actor.
- Debug builds wire `InMemoryBackupService`, which writes no file: the backup half of this work is only
  observable in a Release build or in the service tests (same memory note).
- Git: the root checkout stays on `main`. Work in a worktree under `.worktrees/`, branch
  `feature/attachments-search-sorting` off `origin/main`, and carry this spec file into the branch.
  Conventional Commits with the project's types; merging happens only on Stefano's explicit go-ahead.

## Open questions

- None blocking. D1 to D4 are Stefano's; D5 to D14 were taken here and are open to his review.
