# ADR 0001: Storage of license entries, serials and backups

- Status: accepted
- Date: 2026-11-18

## Context

SerialManager records the licenses of the owner's software. Each entry has descriptive
metadata (product name, vendor, registered email, purchase date, version, notes) and one
sensitive value: the serial number or license key. The app targets macOS 14+, is a
single-user personal tool, and stores everything on the device. The data must survive a
move to a new Mac.

## Decision

1. **Entry metadata lives in SwiftData.** A `License` model holds every field except the
   serial. SwiftData is available on the macOS 14 baseline and gives querying, sorting and
   SwiftUI integration without extra code.
2. **Serials live in the macOS Keychain.** Each serial is a generic password item keyed by
   the stable identifier (UUID) of its `License` entry. The SwiftData store never contains
   a serial.
3. **Backup is an encrypted JSON export.** A single password-protected file contains the
   metadata and the serials, and can be imported on another Mac. This is the only supported
   way to move serials between machines in v1.

## Consequences

- Serials are encrypted at rest by the system and are not readable from the database file.
- An entry and its serial are stored in two places: create, update and delete must keep
  them consistent, and the app must handle an entry whose Keychain item is missing.
- Keychain access goes behind a small protocol so the logic can be unit tested with an
  in-memory fake; tests never touch the real Keychain.
- Copying the SwiftData store alone does not migrate serials: the encrypted export is
  required, and the UI should say so.
- The export needs a key derived from the user's password and authenticated encryption
  (CryptoKit). The exact scheme and file format are decided when the backup milestone starts.

## Alternatives considered

- **Plain JSON file for metadata**: readable and simple, but search, sorting and schema
  migrations would be manual.
- **Serials stored with the metadata**: simpler, but the serials would sit in clear text in
  the database file, protected only by FileVault.
- **CSV export in clear text**: readable anywhere, but exposes every serial.
- **No backup in v1**: leaves no way to move to a new Mac, which is a main reason for the app.
