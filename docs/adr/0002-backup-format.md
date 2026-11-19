# ADR 0002: Backup file format and encryption

- Status: accepted
- Date: 2026-11-19

## Context

ADR 0001 decided that the backup is a single password-protected, encrypted JSON export that
carries the license metadata and the serials, and left the key derivation, the cipher and the
file layout to the backup milestone. This ADR fixes them so that the export and the import
(backlog tickets #9 and #10, not GitHub numbers) can be implemented without further decisions.

Constraints:

- No third-party dependency: the project has none today. System CryptoKit offers authenticated
  encryption but no password-based key derivation (only HKDF); CommonCrypto offers PBKDF2
  (`CCKeyDerivationPBKDF` in `CommonCrypto/CommonKeyDerivation.h`).
- The file type already exists: `.smbackup`, UTType `it.stefer.SerialManager.backup`
  (`Sources/Support/BackupFileType.swift`, declared in `Project.swift`).
- The error vocabulary already exists in `Sources/Contract/LicenseContract.swift`:
  `BackupError.wrongPassword`, `.corruptedFile`, `.unsupportedVersion`. Export reports
  `ExportSummary.missingSerialCount`; import reports `ImportPreview.conflictingIDs` and applies a
  `ConflictPolicy` (`skip` or `replace`).
- The repository is public: test vectors and examples use fake data only.

## Decision

### 1. Key derivation

- PBKDF2-HMAC-SHA256 through CommonCrypto: `CCKeyDerivationPBKDF` with `kCCPBKDF2` and
  `kCCPRFHmacAlgSHA256`, 32-byte (256-bit) output, used as a CryptoKit `SymmetricKey`.
- Default 600,000 iterations, as recommended for PBKDF2-HMAC-SHA256 by the OWASP Password Storage
  Cheat Sheet (master branch, checked 2026-11-19:
  https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
- A new random salt of 16 bytes for every export, from `SecRandomCopyBytes`.
- The KDF identifier, the iteration count and the salt are stored in the file header.

### 2. Cipher

- AES-256-GCM from CryptoKit (`AES.GCM`), 12-byte nonce, 16-byte tag.
- A new random nonce for every export (`AES.GCM.Nonce()`), never reused. Since the salt is also
  new, every export uses a new key as well: two exports of the same data with the same password
  produce different files.

### 3. File layout, version 1

The file is a binary header readable without the password, followed by the ciphertext of the
JSON payload and the GCM tag. All integers are unsigned and big-endian. Offsets are in bytes;
`S` is the salt length, `L` the ciphertext length.

| Offset | Size | Field | Value written by export (v1) | Import rule |
| --- | --- | --- | --- | --- |
| 0 | 8 | magic | ASCII `SMBACKUP` (`53 4D 42 41 43 4B 55 50`) | mismatch -> `corruptedFile` |
| 8 | 2 | format version (UInt16) | `1` | `0` -> `corruptedFile`; above `1` -> `unsupportedVersion` |
| 10 | 1 | KDF id (UInt8) | `0x01` = PBKDF2-HMAC-SHA256 | any other value -> `corruptedFile` |
| 11 | 4 | iterations (UInt32) | `600000` | outside [600,000, 10,000,000] -> `corruptedFile` |
| 15 | 1 | salt length `S` (UInt8) | `16` | outside [16, 64] -> `corruptedFile` |
| 16 | S | salt | 16 random bytes | |
| 16+S | 1 | cipher id (UInt8) | `0x01` = AES-256-GCM | any other value -> `corruptedFile` |
| 17+S | 12 | nonce | 12 random bytes | |
| 29+S | 4 | ciphertext length `L` (UInt32) | byte count of the ciphertext, tag excluded | file size not equal to `33+S+L+16` -> `corruptedFile` |
| 33+S | L | ciphertext | AES-GCM encryption of the UTF-8 JSON payload | |
| 33+S+L | 16 | tag | GCM authentication tag | |

- The header is bytes `[0, 33+S)`: 49 bytes with the v1 defaults. Those exact bytes, as read
  from the file, are passed to AES-GCM as associated data, so a changed header fails
  authentication even when it passes the bound checks.
- The length field makes every truncated file, and every file with trailing bytes, a
  `corruptedFile` before any key is derived.
- One constant, `maxBackupFileSize` = 64 MiB (67,108,864 bytes), caps the whole file on both
  sides. Export computes the final size (`33+S+L+16`) before writing; above the cap it fails
  without creating or changing the destination file, so the app never writes a file it would
  reject. The export error type is defined by #9 (`BackupError` is the import vocabulary) and is
  shown through `ExportModel.Phase.failed`. Export writes the file atomically.
- The envelope is binary and the payload is JSON: the backup is still the "encrypted JSON
  export" of ADR 0001.

Worked example (acceptance example 1): an export with the fake password `sample-backup-pass`
starts with `SMBACKUP`, then `00 01` (version 1), `01` (PBKDF2-HMAC-SHA256), `00 09 27 C0`
(600,000), `10` (16-byte salt), the 16 salt bytes, `01` (AES-256-GCM), the 12 nonce bytes and the
4-byte ciphertext length.

### 4. Import bounds

- Iteration floor 600,000: it is the only count this version of the app writes, so a lower count
  is a downgrade attempt. It rejects trivially low counts such as 1.
- Iteration ceiling 10,000,000: about 17 times the default. It bounds the derivation time a
  crafted file can force (measured below).
- Salt length 16 to 64 bytes. Nonce length (12) and tag length (16) are fixed by the layout.
- Raising the export default within [floor, ceiling] keeps version 1. Writing a count above the
  ceiling, or lowering the floor, requires a new format version, so that older apps answer
  `unsupportedVersion` instead of `corruptedFile`.

### 5. Import order and error mapping

Import runs these steps in order and stops at the first failure:

1. Read only the first 10 bytes (file handle, not the whole file). Fewer than 10 bytes, or a
   magic other than `SMBACKUP` -> `corruptedFile`.
2. Version `0` -> `corruptedFile`; version above `1` -> `unsupportedVersion`. Nothing else is
   checked before this step, so a newer file reports `unsupportedVersion` whatever its size or
   the rest of its header, and no key is derived.
3. File size above `maxBackupFileSize` -> `corruptedFile`. Only then is the rest of the file read.
4. Rest of the header: unknown KDF or cipher id, iterations or salt length out of bounds, a file
   cut inside the header, or a file size not equal to `33+S+L+16` -> `corruptedFile`.
5. Derive the key and open the sealed box with the header as associated data. Authentication
   failure -> `wrongPassword`.
6. Decrypted bytes that are not valid UTF-8 JSON, a missing required key, a wrong type, an invalid
   UUID or date, or two licenses with the same `id` -> `corruptedFile`.

| Case | `BackupError` |
| --- | --- |
| Shorter than 10 bytes, wrong magic, version 0 | `corruptedFile` |
| Version above the newest one the app supports | `unsupportedVersion` |
| Larger than 64 MiB | `corruptedFile` |
| Unknown KDF or cipher id | `corruptedFile` |
| Iterations or salt length out of bounds | `corruptedFile` |
| Truncated file, or trailing bytes | `corruptedFile` |
| Authentication failure | `wrongPassword` |
| Decrypted payload not valid JSON for this version | `corruptedFile` |

Known limit: AES-GCM cannot tell a wrong password from bytes altered after the export. A file
whose ciphertext, tag or header was changed, but whose header still passes the checks of steps
1 to 4, reports `wrongPassword` ("The password is incorrect.").

### 6. Payload

The plaintext is a UTF-8 JSON object, with no compression:

```json
{
  "exportedAt": "2026-11-19T10:00:00.000Z",
  "licenses": [
    {
      "id": "00000000-0000-4000-8000-000000000001",
      "productName": "Sample Editor",
      "vendor": "Example Software",
      "registeredEmail": "user@example.com",
      "purchaseDate": null,
      "version": "1.0",
      "notes": "",
      "createdAt": "2026-01-01T09:00:00.000Z",
      "updatedAt": "2026-01-01T09:00:00.000Z",
      "serial": "FAKE-0000-0000-0000"
    }
  ]
}
```

- `exportedAt` is the export date. Each element of `licenses` carries every field of
  `LicenseSummary` plus `serial`. `id` is the UUID string; `purchaseDate` is null when unset.
  `licenses` may be empty.
- The payload key `version` is the product version string of `LicenseSummary` (for example
  `"1.0"`), not the file format version. The format version lives only in the clear header and
  never appears in the payload.
- Dates are ISO 8601 in UTC with a `Z` suffix and exactly three fractional digits
  (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, that is `ISO8601DateFormatter` with `.withInternetDateTime`
  and `.withFractionalSeconds`). The default `JSONEncoder` `.iso8601` strategy drops the
  fractions, so #9 uses a custom strategy. Import accepts this form and the same form without
  fractional seconds.
- `serial` is a string, or null when the Keychain item is missing. A Keychain item that exists but
  holds an empty value is also exported as null. Export never writes `""`, and every null serial
  is counted in `ExportSummary.missingSerialCount`. Import treats `""` exactly like null.
- Unknown keys are ignored on import.

Applying an import:

- No conflict, `serial` non-null: the entry is created in SwiftData and its serial in the Keychain.
- No conflict, `serial` null: the entry is created with no Keychain item; the detail view shows it
  as an entry whose serial is missing, as for any such entry.
- Conflict (an entry with the same `id` exists on this Mac), `ConflictPolicy.replace`:
  - `serial` non-null: the metadata and the Keychain item are both replaced.
  - `serial` null: only the metadata is replaced. The existing Keychain item on this Mac is kept;
    an import never deletes a Keychain item.
- Conflict, `ConflictPolicy.skip`: the local entry and its Keychain item are left untouched.

### 7. Versioning

- Version 1 is the format described in this ADR.
- Any incompatible change bumps the format version: a change to the header layout, a new KDF or
  cipher, new import bounds that older apps would reject, or removing, renaming or retyping a
  payload key, or adding a required one.
- Adding an optional payload key (absent or null in older files) is compatible and keeps the
  current version. An older app ignores the key and loses it if it re-exports the data.
- The app keeps reading every format version it has ever written. A new version adds a reader;
  it never removes an old one.
- A file whose version is above the newest one the app supports fails with
  `unsupportedVersion` ("This backup was made with a newer version of SerialManager.") at step 2
  of the import, before any key is derived.
- Export always writes the newest version.

### 8. Password

- Export requires at least 12 characters, counted as Swift `Character`s, with no trimming. Below
  that, Export disabled: `ExportModel.canExport` is false (enforced by #9, which also updates
  `docs/design/gui.md`). For example `short-pass` (10 characters): Export disabled.
- Import accepts any non-empty password.
- Before derivation the password is normalized to Unicode NFC with
  `String.precomposedStringWithCanonicalMapping` and encoded as UTF-8, so the same password typed
  with another keyboard or input method gives the same key.
- The password, the derived key and the decrypted payload are never persisted, logged or included
  in error messages.

## Consequences

- Key derivation has a cost on both export and import. Measured on 2026-11-19 on an Apple M5 Max
  (`swiftc -O`, `CCKeyDerivationPBKDF`, SHA-256, 32-byte key): 0.068 s at 600,000 iterations and
  1.159 s at the 10,000,000 ceiling. Older Macs are slower. Derivation runs off the main actor and
  the sheets show their progress state while it runs.
- The #9 and #10 tests need fixed test vectors. Import is pinned by a known file (fake password,
  salt, nonce and payload) that must decrypt to the expected licenses. Export is checked by round
  trip through import and by its header fields; a byte-exact export vector would also need an
  injectable clock for `exportedAt` and a fixed key order (`JSONEncoder.OutputFormatting.sortedKeys`),
  so the service takes injectable salt, nonce and clock sources. Vectors use fake data and fake
  passwords only, including one non-ASCII password with a decomposed accent to pin the NFC rule.
  They derive at the real 600,000 floor; the import bounds are not made injectable to speed tests
  up. Dates round-trip at millisecond precision, so tests compare `createdAt` and `updatedAt` at
  that precision.
- Moving to scrypt or Argon2id later means a new KDF id and a new format version; the app keeps
  reading version 1 files.
- A lost password makes the backup unrecoverable: there is no reset or recovery path, and the UI
  should say so at export time.
- A wrong password and a tampered file give the same message (known limit above).
- An import can add serials but never removes one from the Keychain.

## Alternatives considered

- **scrypt via swift-crypto (`CryptoExtras`)**: memory-hard, so stronger against GPU attacks, but it
  adds the project's first dependency (BoringSSL based). Rejected for now; it can come later as a
  new format version.
- **Argon2id via a third-party library**: the first choice of the OWASP cheat sheet cited above, but no
  Apple framework provides it and it needs a C library or an extra package. Rejected for the same
  reason.
- **ChaChaPoly (CryptoKit)**: equally sound authenticated encryption. AES-GCM is chosen because it
  is the more common choice and has hardware support on Apple silicon and on Intel Macs with AES-NI; ChaChaPoly would
  have the same layout with another cipher id.
- **JSON envelope** (header fields as JSON, base64 ciphertext): readable in a text editor, but the
  exact bytes to authenticate, the bounds and the "version before KDF" order are harder to state
  and to check, and base64 grows the file by a third.
- **CSV export in clear text**: readable anywhere, but it exposes every serial (already rejected in
  ADR 0001).
- **No minimum password length**: simpler, but a short password makes an offline attack on a copied
  backup cheap whatever the iteration count.
