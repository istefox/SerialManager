# ADR 0004: Attachment storage

- Status: accepted
- Date: 2026-11-23

## Context

Ticket #18 adds files attached to a license: a licence file, an invoice, a screenshot of a
registration page. SPEC 0018 (`docs/specs/0018-attachments-search-sorting.md`) fixes the product
decisions; this ADR fixes where the bytes live and how they are protected, which ADR 0001 left
open ("entry metadata in SwiftData, serials in the Keychain").

Constraints that shaped the decision:

- The attachments are as sensitive as the serials: a licence file usually *contains* the serial.
  Plaintext copies in Application Support would undo ADR 0001.
- The Keychain is the wrong store for the bytes themselves. A generic password item is meant for
  small secrets; a 5 MB item per attachment is an abuse of it, and the Keychain holds no per-item
  file name or content type.
- SwiftData external storage (`@Attribute(.externalStorage)`) writes the bytes in the clear next
  to the store.
- `Project.swift` declares one bundle identifier for every configuration, so Debug and Release
  share both the Application Support folder and the Keychain service. A test that reached either
  would read, and could destroy, the owner's own library.
- The backup is a single encrypted file capped at 64 MiB (ADR 0002), and the attachments must
  survive a move to another Mac (SPEC 0018, D2).

## Decision

### 1. One encrypted file per attachment, named by its id

- Bytes: `<Application Support>/<folder>/Attachments/<attachment id>`, sealed with AES-256-GCM
  (CryptoKit `AES.GCM.seal`, the `combined` representation: 12-byte nonce, ciphertext, 16-byte
  tag). `Sources/Data/Attachments/AttachmentFileStore.swift`.
- Metadata: an `AttachmentRecord` row in the same SwiftData store as the licenses, carrying `id`,
  `licenseID`, `fileName`, `contentType`, `byteCount` (of the plaintext) and `addedAt`. No bytes.
- The file on disk is named by the attachment's UUID, never by the user's file name: a folder
  listing must not say which software the owner owns.
- `AttachmentRecord` has no SwiftData relationship to `License`. It is keyed by `licenseID`, the
  same keyed-by-UUID shape the Keychain already uses for serials. Adding an entity is a
  lightweight SwiftData migration; changing `License` would not be, and `License` is unchanged by
  this ticket.

### 2. One library key in the Keychain, add-only

- A single 32-byte AES key protects every attachment of the library. It is a generic password item
  with the attributes ADR 0003 fixes for serials: service = the bundle identifier, account =
  `attachment-key` (a fixed name, so it can never collide with a serial item keyed by a license
  UUID), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable, data protection
  keychain.
- `AttachmentKeyStore` has two operations, `key()` and `addKey(_:)`. There is no update and no
  delete. A duplicate item on add means another caller won the race: the existing key is read back
  and returned, never overwritten.
- A key is generated **only** when the Keychain answers item-not-found *and* the library holds no
  attachment. Every other failure, access denied above all, throws and generates nothing.
  Minting a replacement key while files remain on disk would make every one of them permanently
  unreadable while the app looked healthy.
- One key per library, not one per attachment: the per-attachment nonce already makes every file's
  ciphertext unique, and a key per attachment would mean one Keychain item per file, each one a
  prompt the user has to answer.

### 3. Injectable directory and service, no production default below `LicenseLibrary`

- `AttachmentFileStore(directory:keys:)` takes both; neither has a default. `LicenseLibrary` is
  the only place that passes `defaultAttachmentsDirectory` and `KeychainAttachmentKeyStore()`.
- A default of the real Keychain store would let a test that overrides only the directory create
  or read the real library key. With no default, isolation is checked by the compiler, not by
  review. `Tests/AttachmentIsolationAuditTests.swift` pins it by reading the source.

### 4. The app never deletes a file it has no row for

Removing an attachment deletes the row and the file. A file with no row is left exactly where it
is: Debug and Release share the folder, so a sweep of "orphan" files run by one build would delete
the other build's attachments. The opposite orphan, a row whose file is gone, is shown in the
detail view as an unreadable attachment the user can remove.

### 5. Writes are compensated, not transactional

Adding an attachment writes the file first, then the row. If the row fails to persist, the file
just written is deleted before the error is reported. There is no two-phase commit across the file
system and SwiftData, so the invariant the app keeps is the one that matters to the user: no row
points at a missing file *because of the app*.

### 6. Export skips an attachment whose file is already gone

An attachment row whose file is missing is skipped and counted in
`ExportSummary.missingAttachmentCount`, exactly as a missing Keychain item is exported as a null
serial and counted. Any other failure, a key that cannot be read or bytes that do not
authenticate, aborts the export. Decision 4 allows a row whose file was removed behind the app's
back to exist, and such a row must not be able to block every backup of every other license
(decided by the project owner, 2026-11-23).

### 7. Size budget

Plaintext limits, in decimal bytes as the Finder counts them, in
`Sources/Data/Attachments/AttachmentLimits.swift`:

| Limit | Value |
| --- | --- |
| One file | 5,000,000 |
| One license | 20,000,000 |
| The whole library | 40,000,000 |

The library total is what keeps a full library inside the 64 MiB backup cap once base64 has
inflated the bytes by 4/3 (40,000,000 × 4/3 ≈ 53.3 MB, plus the metadata). An **import** never
applies these limits: a backup is authoritative, so restoring a library that is over the total
must succeed. `maxBackupFileSize` stays the only hard stop, and it is checked before the file is
written.

### 8. Opening an attachment writes a plaintext copy

Open decrypts into `<temp>/OpenedAttachments/<uuid>/<file name>` and hands that path to
`NSWorkspace`. The directory is deleted at launch and at quit. The copy is plaintext for as long
as the user has it open, which is the point: there is no way to hand a file to another application
without giving it readable bytes. Save a Copy… writes wherever the user chooses and is their
copy to keep.

## Consequences

- An attachment is readable only on the Mac that holds the Keychain key, as a serial already is.
  Copying the Attachments folder to another Mac yields unreadable files; the backup is the
  supported way to move them (ADR 0002, version 2).
- Losing the Keychain item makes every attachment permanently unreadable. The app says so instead
  of silently minting a new key, and the message points at a Keychain backup or a SerialManager
  backup.
- The store holds one more entity, so the next schema change must keep both.
- An attachment is never deduplicated: the same file attached to two licenses is two files.
- A `byteCount` in the store is the plaintext size; the file on disk is 28 bytes larger.

## Alternatives considered

- **Bytes in SwiftData, `@Attribute(.externalStorage)`**: one store to back up and no key
  management, but the bytes land in the clear next to the store. Rejected: it contradicts ADR 0001.
- **Bytes in the Keychain, one item per attachment**: consistent with the serials and protected by
  the system, but the Keychain is not a file store, each item would carry no name or type of its
  own, and a 5 MB generic password item is an abuse of the API. Rejected.
- **A reference to the user's own file instead of a copy** (a bookmark): no duplicated bytes and no
  size limit, but the app would show attachments that vanish when the user tidies up their
  Downloads folder, and a backup could not carry them. Rejected; SPEC 0018 D1 asks for copies.
- **One key per attachment**: a smaller blast radius per key, but one Keychain item per file and a
  prompt per file. Rejected.
- **A relationship on `License`** instead of `licenseID`: idiomatic SwiftData and cascade delete
  for free, but it changes the existing entity, which turns a lightweight migration into a risk to
  the owner's store. Rejected for this ticket.
