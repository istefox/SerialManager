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
  (localized, case-insensitive). Row: product name (headline) and vendor (secondary,
  one line, tail truncation allowed only for the vendor). `.searchable` in the sidebar,
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

Sections: **Product** (name, vendor, version), **License** (serial, registered email,
purchase date), **Notes**, footer with created and modified dates in secondary text.

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
keys), Registered email, Purchase date (optional: a toggle "Purchase date" reveals a
`DatePicker`), Notes (multi-line).

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

File > Export Licenses... (`Cmd+Shift+E`), disabled when there are no licenses.

1. Sheet: explanation ("The backup contains all licenses and serials, encrypted with this
   password. You need it to restore the backup."), Password, Confirm password.
   Export is disabled until both are non-empty and equal; mismatch shows an inline message.
2. System save panel, default name `SerialManager Backup YYYY-MM-DD.smbackup`.
3. Summary: "Exported 12 licenses." and "Without a serial in the Keychain: 1", plus
   "Show in Finder".

States: Entering password, Mismatch, Exporting (progress), Done (summary), Failed (alert).

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

States: Password entry, Wrong password, Corrupted file, Conflicts found, Importing, Done.

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
creates a license. License commands are disabled without a selection. Menu commands reach
the window through `AppRouter` (an `@Observable` request bus).

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
            registeredEmail: license.registeredEmail,
            purchaseDate: license.purchaseDate,
            version: license.version,
            notes: license.notes,
            serial: serial ?? ""
        )
    }
}

protocol LicenseRepository: Sendable {
    func fetchAll() async throws -> [LicenseSummary]
    func create(_ draft: LicenseDraft) async throws -> LicenseSummary
    func update(id: UUID, with draft: LicenseDraft) async throws -> LicenseSummary
    func delete(id: UUID) async throws
    /// Returns nil when the Keychain item for this license is missing.
    func serial(for id: UUID) async throws -> String?
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
    func export(to url: URL, password: String) async throws -> ExportSummary
    func prepareImport(from url: URL, password: String) async throws -> ImportPreview
    func applyImport(_ preview: ImportPreview, policy: ConflictPolicy) async throws -> ImportSummary
}
```

Semantics the data layer must keep:

- `update(id:with:)` with an empty `serial` removes the Keychain item (the user cleared it).
  The form refuses to save an empty serial when the current one could not be read, so a
  Keychain read error never turns into a silent delete.
- `fetchAll()` order does not matter: the GUI sorts by product name.
- `prepareImport` decrypts and validates the file and must keep the decrypted payload until
  `applyImport` is called with the returned preview (the preview carries only counts, ids
  and the file URL). Errors: `BackupError` for a wrong password, a corrupted file or a newer
  format; any other error is shown as a generic failure.

`SerialStore` (Keychain) stays internal to the data layer: the GUI only sees
`LicenseRepository`. The GUI ships in-memory fakes of both protocols with obviously fake
sample data (`ACME-0000-TEST-0000`, `user@example.com`) for previews and tests.

## Sample data

The GUI runs on the in-memory fakes in `Sources/Fakes` until the data layer lands.
`SampleData` and the preview helpers are compiled only in Debug: a Release build starts
with an empty in-memory store and contains no sample values. When the data layer is ready,
`SerialManagerApp.init` is the single place to swap the fakes for the real implementations.

## Known gaps

- Menu commands stay enabled while a sheet is open; the window ignores New and Edit while
  the form is up.
- The "Main, loading" preview shows the loaded list almost at once: the fake repository
  answers immediately.
- Release builds are an empty, non-persistent shell until the data layer lands. They use
  `UnavailableBackupService`: Import and Export are disabled in the File menu, and the
  service fails if reached anyway, so no build reports a backup that was never written.

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
