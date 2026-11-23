# GUI design

- Status: accepted (decisions of 2026-11-18 below)
- Date: 2026-11-18
- Covers: backlog items #5 (main window), #6 (form), #7 (detail), #9 (export), #10 (import)
- Builds on: `docs/adr/0001-storage.md`

## Principles

1. **Native first.** Standard SwiftUI controls, system colors, SF Symbols, no custom chrome.
   Light and dark mode come for free; no hard-coded colors.
2. **The serial is the only sensitive thing on screen.** It is masked by default, revealed
   only on request, and never shown in the list.
3. **The GUI never touches storage.** Views talk to an `@Observable` store that depends on
   protocols (see "Contract with the data layer"). SwiftData and Keychain stay behind them.
4. **Every screen has named states**, each with its own `#Preview`.

## Visual direction

Quiet utility, in the family of Passwords.app and Notes: a plain sidebar list, a detail pane
that reads like a record card, one accent (system accent color). Each entry shows a generic
SF Symbol (`key.horizontal`) rather than real app icons: no file access, no guessing.

The detail pane is a grouped `Form` (`.formStyle(.grouped)`) in read-only mode: labels on
the left, values on the right, the serial in a monospaced field with its two actions.
Empty optional fields are hidden, not shown as blank rows.

## Windows and scenes

| Scene | Type | Notes |
| --- | --- | --- |
| Main window | `WindowGroup` | Single window in practice; minimum 720 x 440 pt. |
| License form | Sheet on the main window | Same view for create and edit. |
| Export | Sheet, then system save panel | Password twice, then `NSSavePanel`. |
| Import | System open panel, then sheet | `NSOpenPanel`, then password, then conflicts. |
| Settings | `Settings` scene | `Cmd+,`, one pane: clipboard clearing. |

Sheets instead of separate windows: each task is short, modal and tied to the main window,
which matches HIG guidance for sheets on macOS.

## Main window

`NavigationSplitView` with two columns.

- **Sidebar** (min 220 pt): `List` with selection, sorted by product name
  (localized, case-insensitive). Row: product name (headline) and vendor (secondary);
  both wrap with no line limit, so a long name is never truncated (SPEC 0005, D3).
  `.searchable` in the sidebar,
  matching product name and vendor, case and diacritic insensitive.
- **Detail**: the selected license, or a placeholder.

Toolbar: `+` New License (primary action). In the detail column: Edit, Delete.

### States

| State | Sidebar | Detail |
| --- | --- | --- |
| Loading | `ProgressView` | Empty |
| Empty (no licenses) | Empty list | `ContentUnavailableView` "No Licenses" + button "Add License" |
| No selection | List | `ContentUnavailableView` "Select a License" |
| Search, no results | `ContentUnavailableView.search(text:)` | Unchanged |
| Load error | Empty list | `ContentUnavailableView` with the error and "Try Again" |

## Detail

Sections: **Product** (name, vendor, version), **License** (serial, registered name, registered
email, purchase date), **Notes**, footer with created and modified dates in secondary text.

Serial row:
- Masked by default as a fixed run of dots (fixed length, so the real length is not leaked).
- Eye button toggles Show / Hide. The serial hides again when the selection changes.
- Copy button writes to `NSPasteboard`; the button label turns into "Copied" with a
  checkmark for 1.5 s and VoiceOver announces "Serial copied".
- If clipboard clearing is on (Settings), the pasteboard is cleared after the delay, but
  only if it still holds the copied serial (checked via `changeCount`), so later copies
  made by the user are never wiped.
- Text is selectable only while revealed.

### States

| State | What the user sees |
| --- | --- |
| Serial present, masked | Dots, Show and Copy enabled |
| Serial present, revealed | Monospaced serial, Hide and Copy |
| Copied | Copy button shows "Copied" briefly |
| Serial missing | Warning row: "The serial for this license is missing from the Keychain." + "Add Serial..." opening the edit form focused on the serial |
| Serial loading | Small `ProgressView` in the serial row |
| Notes empty, optional fields empty | Rows hidden |

## License form

One view, two modes (New License, Edit License), presented as a sheet.

Fields: Product name (required), Vendor, Version, Serial (multi-line, monospaced, for long
keys), Registered name (the person the license is registered to, "nome e cognome"), Registered
email, Purchase date (optional: a toggle "Purchase date" reveals a `DatePicker`), Notes
(multi-line).

- **Save** is the default button (`Enter`), **Cancel** the cancel button (`Esc`).
- Validation: Save with an empty product name shows an inline message under the field,
  "Product name is required", and moves focus there. Whitespace-only counts as empty.
- **Cancel** discards. If the draft has changes, a confirmation "Discard changes?" first.
- Edit mode adds a destructive **Delete License...** button at the bottom left.
- Delete (here, in the toolbar, from the License menu, or with `Backspace` in the list) asks
  for confirmation:
  "Delete 'Product'? This also removes its serial from the Keychain. This can't be undone."

### States

New empty, New with validation error, Edit, Edit with unsaved changes (discard prompt),
Add missing serial (focus on the serial), Saving (buttons disabled), Save error (alert).
Sheets have no title bar on macOS, so each sheet shows its title in a `SheetHeader`.

## Export

File > Export Licenses... (`Cmd+Shift+E`), disabled when there are no licenses or the
backup service reports `isExportAvailable == false`.

1. Sheet: explanation ("The backup contains all your licenses and serials, encrypted with
   this password. You need it to restore the backup: it can't be recovered if you forget it."),
   Password, Confirm Password, and a permanent hint under the fields: "Use at least 12
   characters." (`.callout`, secondary).
   Export is disabled until the password has at least 12 characters and the confirmation is
   equal. Characters are Swift `Character`s (an accent typed as a combining mark does not count
   on its own), with no trimming: spaces count. `ExportModel.minimumPasswordLength` holds the
   number; the hint repeats it, so the two change together. A mismatch shows an inline message.
2. System save panel, default name `SerialManager Backup YYYY-MM-DD.smbackup`.
3. Summary: "Exported 12 licenses." and "Without a serial in the Keychain: 1", plus
   "Show in Finder".

States: Entering password, Password too short (Export disabled, hint visible), Mismatch,
Exporting (progress), Done (summary), Failed.

Failed is a state of the sheet, not an alert: an icon, "Export Failed", the error message, and
Cancel or Try Again. Try Again returns to the password form with both fields kept. Messages:

- File too large: "The backup is larger than 64 MB, the maximum size."
- Encryption failure (system error, not user input): "The backup couldn't be encrypted. Try again."
- A serial can't be read from the Keychain: the export stops, no file is written, and the
  sheet shows the existing Keychain message ("Keychain access was denied...").
- Library or file write errors: the existing message of that error, unchanged.

In every failure the destination file is neither created nor modified.

## Import

File > Import Licenses... (`Cmd+Shift+I`).

1. System open panel, filtered to the backup file type.
2. Sheet: file name, Password field, Import button.
3. Errors shown inline in the sheet, with the password kept for a retry:
   - wrong password: "The password is incorrect.",
   - corrupted or unreadable file: "This file isn't a valid SerialManager backup.",
   - newer format: "This backup was made with a newer version of SerialManager."
4. If some licenses already exist (same id): "Already in SerialManager: 4 of 12 licenses."
   with a segmented choice **Skip** (default, safe) / **Replace**, applied to all of them.
   Without conflicts the import runs right away.
5. Summary: imported N, replaced N, skipped N.

States: Password entry, Wrong password, Corrupted file, Conflicts found, Importing, Done, Failed.

Release builds run the real import (`EncryptedBackupService`, #10). Import is enabled also with an
empty library, the new-Mac case.

- **Skip** leaves every existing license exactly as it is, dates and serial included.
- **Replace** overwrites every field and both dates with the backup's. The serial is replaced
  only when the backup has one: a license the backup holds without a serial keeps its local
  serial. An import never deletes a serial from the Keychain.
- A license the backup holds without a serial is created with no Keychain item.
- If a write fails during the import, the import stops there and keeps what it already wrote.
  The sheet shows Import Failed with "The import stopped. Imported: N. Replaced: N." followed
  by the error's own message, and the list is reloaded so the licenses already imported appear.
  Importing the same file again shows them as conflicts.
- The decrypted backup is kept in memory only between the password and the Import button of
  the conflict step. Cancel at the password, checking or conflict step, and any other way the
  sheet closes before Import (`Esc`, the sheet replaced), call `cancelImport()`, so the payload
  is dropped at once (D5, SPEC 0010 R17). Once Import has started nothing is cancelled: Done and
  Close only close the sheet. The sheet calls `ImportModel.close()` from `onDisappear` on its
  root container, never on a `Group` or a phase branch, which would fire on a phase change.

## Menus and keyboard shortcuts

| Menu | Command | Shortcut |
| --- | --- | --- |
| SerialManager | Settings... | `Cmd+,` (system) |
| File | New License | `Cmd+N` |
| File | Import Licenses... | `Cmd+Shift+I` |
| File | Export Licenses... | `Cmd+Shift+E` |
| Edit | Find (focus search) | `Cmd+F` (system) |
| Edit | Delete (list focused) | `Backspace` (system, via `onDeleteCommand`) |
| License | Edit License | `Cmd+E` |
| License | Copy Serial | `Cmd+Shift+C` |
| License | Show or Hide Serial | `Cmd+Shift+R` |
| License | Delete License... | none |

`File > New Window` is replaced (`CommandGroup(replacing: .newItem)`), since `Cmd+N`
creates a license. License commands are disabled without a selection. Copy Serial and
Show or Hide Serial are also disabled while the selected entry's serial is loading,
missing or failed to load. Menu commands reach the window through `AppRouter` (an
`@Observable` request bus).

Delete has no `Cmd+Backspace` shortcut on purpose: a menu shortcut would win over the text
fields, so `Cmd+Backspace` in the search field would ask to delete the selected license
instead of erasing the text. The standard Edit > Delete with `Backspace` only fires when the
list has focus.

## Accessibility

- Every icon-only button has a text label (`Label` with `.labelStyle(.iconOnly)`).
- The masked serial reads as "Serial, hidden" to VoiceOver; revealed it reads the value.
- The copy confirmation is posted as an accessibility announcement.
- Text uses semantic styles (`.headline`, `.body`, `.caption`), so it follows the user's
  text size where macOS applies it; no fixed font sizes.
- At the minimum window size no label is truncated: field labels are short, values wrap.

## Contract with the data layer

The GUI uses value types, not the SwiftData `@Model`, so the views and previews do not
depend on SwiftData. The data layer maps its model to these types. All names are proposals
for the team implementing #2, #3, #4, #9, #10.

```swift
/// Read-only copy of one license, without the serial.
struct LicenseSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var productName: String
    var vendor: String
    var registeredName: String
    var registeredEmail: String
    var purchaseDate: Date?
    var version: String
    var notes: String
    let createdAt: Date
    var updatedAt: Date
}

/// What the license form edits; includes the serial.
struct LicenseDraft: Equatable, Sendable {
    var productName = ""
    var vendor = ""
    var registeredName = ""
    var registeredEmail = ""
    var purchaseDate: Date?
    var version = ""
    var notes = ""
    var serial = ""

    /// True when the product name has visible characters.
    var hasValidProductName: Bool {
        !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Copy with surrounding whitespace removed from every single-line field.
    var normalized: LicenseDraft {
        var copy = self
        copy.productName = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.vendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.registeredName = registeredName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.registeredEmail = registeredEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

extension LicenseDraft {
    /// Draft prefilled from an existing license and its serial (nil when missing).
    init(_ license: LicenseSummary, serial: String?) {
        self.init(
            productName: license.productName,
            vendor: license.vendor,
            registeredName: license.registeredName,
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            serial: serial ?? ""
        )
    }
}

/// What `LicenseRepository.importLicense` did with one license of a backup.
enum LicenseImportOutcome: Equatable, Sendable {
    case created
    case replaced
    case skipped
}

protocol LicenseRepository: Sendable {
    func fetchAll() async throws -> [LicenseSummary]
    func create(_ draft: LicenseDraft) async throws -> LicenseSummary
    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary
    func delete(id: UUID) async throws
    /// Returns nil when the Keychain item for this license is missing.
    func serial(for id: UUID) async throws -> String?
    /// Writes one license read from a backup, keeping its id, fields and both dates. Looks the
    /// id up first and never relies on the SwiftData upsert. Used by the import only.
    func importLicense(_ license: LicenseSummary, serial: String?, policy: ConflictPolicy) async throws
        -> LicenseImportOutcome
}

struct ExportSummary: Equatable, Sendable {
    let licenseCount: Int
    let missingSerialCount: Int
}

/// A decrypted backup, ready to be applied.
struct ImportPreview: Equatable, Sendable {
    let fileURL: URL
    let licenseCount: Int
    let conflictingIDs: Set<UUID>
}

enum ConflictPolicy: Sendable {
    case skip
    case replace
}

struct ImportSummary: Equatable, Sendable {
    let imported: Int
    let replaced: Int
    let skipped: Int
}

enum BackupError: Error, Equatable {
    case wrongPassword
    case corruptedFile
    case unsupportedVersion
}

protocol BackupService: Sendable {
    /// False while the File menu must keep Export disabled for this service.
    var isExportAvailable: Bool { get }
    /// False while the File menu must keep Import disabled for this service.
    var isImportAvailable: Bool { get }
    func export(to url: URL, password: String) async throws -> ExportSummary
    func prepareImport(from url: URL, password: String) async throws -> ImportPreview
    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary
    /// Drops the payload kept by `prepareImport`, if any. Idempotent, never throws, writes nothing.
    /// No default implementation: every conformer implements it.
    func cancelImport() async
}

extension BackupService {
    var isExportAvailable: Bool { true }
    var isImportAvailable: Bool { true }
}
```

Semantics the data layer must keep:

- `update(id:with:)` with an empty `serial` removes the Keychain item (the user cleared it).
  The form refuses to save an empty serial when the current one could not be read, so a
  Keychain read error never turns into a silent delete.
- `fetchAll()` order does not matter: the GUI sorts by product name.
- `isExportAvailable` and `isImportAvailable` are protocol requirements, so a concrete
  service's values are seen through `any BackupService` (an actor declares them `nonisolated`).
  The File menu enables Export and Import from them separately.
- `prepareImport` decrypts and validates the file and must keep the decrypted payload until
  `applyImport` is called with the returned preview (the preview carries only counts, ids
  and the file URL). Errors: `BackupError` for a wrong password, a corrupted file or a newer
  format; any other error is shown as a generic failure.
- `applyImport` uses the payload once: after it, or after `cancelImport()`, an apply with the
  same preview fails with a generic error and writes nothing.
- `importLicense` per license: no license with that id creates it (a nil or `""` serial writes
  no Keychain item); `.skip` on an existing id changes nothing and touches no serial; `.replace`
  replaces every field and both dates, and the serial only when non-nil and non-empty. It never
  deletes a Keychain item that existed before the call; on failure it undoes its own write.

`SerialStore` (Keychain) stays internal to the data layer: the GUI only sees
`LicenseRepository`. The GUI ships in-memory fakes of both protocols with obviously fake
sample data (`ACME-0000-TEST-0000`, `user@example.com`) for previews and tests.

## Sample data

Debug builds and previews run on the in-memory fakes in `Sources/Fakes`. `SampleData` and
the preview helpers are compiled only in Debug, so a Release build contains no sample values.
A Release build uses the real repository instead: entries persist in SwiftData and serials in
the Keychain (ticket #4). `SerialManagerApp.init` is the single place that picks the fakes or
the real implementations.

## Known gaps

- Menu commands stay enabled while a sheet is open; the window ignores New and Edit while
  the form is up.
- The "Main, loading" preview shows the loaded list almost at once: the fake repository
  answers immediately.
- Release builds persist entries: SwiftData for the entry fields, the Keychain for the
  serials (ticket #4). Debug builds and previews stay on the in-memory fakes.
- Release builds use `EncryptedBackupService` (#9, #10) for Export and Import.
  `UnavailableBackupService` (both flags false) remains for a build that must offer no backup
  at all.
- A backup file altered after export, whose header still passes the checks, reports "The
  password is incorrect." like a wrong password: authenticated encryption cannot tell the two
  apart (ADR 0002, accepted limit).
- If the Keychain holds an orphan item under the id of a license that the import creates with
  no serial (nil or `""` in the backup), the item is kept and the new license shows that
  serial. Accepted: an import never deletes a Keychain item.
- When the sheet closes while the password is being checked, `cancelImport()` runs at close and
  once more when the check returns. If the user reopens Import on another file within that
  moment (under a second), the late call can drop the new payload and its Import fails with the
  generic error; importing again works. Accepted (plan 0010, review round 4).
- If the library file cannot be opened at launch, the window shows "Couldn't Load Licenses"
  with a dedicated message (D8, D10), and creating, editing or deleting fails with the same
  message. The app never falls back to an in-memory store. Try Again cannot succeed in that
  state, because the repository is fixed at launch: the message says to quit and reopen. A
  working Try Again is a follow-up.
- Only three failures have a dedicated message: Keychain access denied, the library file
  that cannot be opened, and an import stopped by a write error (its counts, then the
  underlying message). Every other error shows the generic system text.

## Out of scope

Real app icons per entry, categories or tags, multiple windows, iCloud, a menu bar extra,
auto-hiding a revealed serial after a delay, opening a backup by double-clicking it in Finder.

## Settings

`Settings` scene, one `Form`:
- "Clear Clipboard": Never, After 30 Seconds, After 1 Minute (default), After 2 Minutes.
  Stored with `@AppStorage` (a preference, not license data).
- A copied serial is also marked with `org.nspasteboard.ConcealedType`, so clipboard
  managers that follow the nspasteboard.org convention do not record it.

## Localization

English and Italian from v1, following the system language. All user-facing strings go
through a String Catalog (`Resources/Localizable.xcstrings`), with English as the
development language. `SWIFT_EMIT_LOC_STRINGS` is on, so Xcode keeps the catalog in sync. Previews include an Italian variant of the main window to catch
truncation from longer Italian labels.

## Backup file type

Extension `.smbackup`, exported type `it.stefer.SerialManager.backup` conforming to
`public.data`, declared in the Info.plist through `Project.swift`. The save and open panels
filter on this type. Opening a backup by double-clicking it in Finder is a follow-up: it
needs a document type declaration and file-open handling, not built in v1 of the GUI.

## Decisions (2026-11-18, project owner)

1. UI language: English and Italian from v1.
2. Settings window: yes, with clipboard clearing only.
3. Backup file extension: `.smbackup`.

## App icon

A brass key on a deep navy tile: the key's bit is a stepped code profile and its shaft is
engraved with an obviously fake serial (`A1B2-C3D4`), so the "license key" reads literally.
A row of faint dots along the bottom echoes the masked serial in the detail view.

- Source: `docs/design/icon/AppIcon.svg` (1024 × 1024, macOS tile 824 × 824, radius 185).
- PNGs in `Resources/Assets.xcassets/AppIcon.appiconset`, 16 to 1024 px, rendered from the
  SVG with AppKit. Shadows are layered shape copies, not SVG filters, because AppKit's SVG
  renderer ignores filters.
- To change the icon, edit the SVG and render every size again.
