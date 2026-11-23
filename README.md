# SerialManager

[![CI](https://github.com/istefox/SerialManager/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/istefox/SerialManager/actions/workflows/ci.yml)

A macOS app to keep track of the serial numbers and license keys of your software.

## Status

Usable for daily work: add, edit and delete licenses, search, copy a serial with automatic
clipboard clearing, encrypted backup export and import. Under active development.

## Requirements

- macOS 14 or later
- Xcode with Swift 6
- [Tuist](https://tuist.dev) 4, version pinned in `mise.toml` (`mise install`)

## Install

There is no downloadable build: you build a signed Release app yourself.

```bash
tuist generate --no-open
xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/release -allowProvisioningUpdates build
```

The app lands in `build/release/Build/Products/Release/SerialManager.app`. Copy it to
`/Applications` and open it from there.

Serials are stored in the macOS Keychain, and the app can reach the Keychain only when it is
signed with an Apple Development team. `Project.swift` pins the owner's team in
`DEVELOPMENT_TEAM`: if you build with your own Apple account, set your team there first.

The Debug build (the `build` command below, or Run in Xcode with the Debug configuration) is for
development only: it shows fake sample data and keeps nothing you type, and Export writes no
file.

## Using SerialManager

The app follows the system language (English or Italian). Labels below are given in English,
with the Italian label in brackets.

### Add a license

1. Choose File > New License (Nuova licenza), press `Cmd+N`, or click the "+" button in the
   toolbar. With an empty list you can also click Add License (Aggiungi licenza).
2. Fill in the form. Product Name (Nome prodotto) is the only required field; Vendor
   (Produttore), Version (Versione), Serial (Seriale), Registered Name (Nome e cognome),
   Registered Email (Email di registrazione) and Notes (Note) are optional. Example: Product
   Name `Acme Editor`, Vendor `Acme`, Serial `ACME-0000-TEST-0000`, Registered Name
   `Jane Appleseed`, Registered Email `user@example.com`.
3. Click Save (Salva). The license appears in the sidebar list and its serial goes to the
   Keychain.

To change a license, select it and choose License > Edit License (Licenza > Modifica licenza),
press `Cmd+E`, or click Edit (Modifica) in the toolbar. To delete it, choose License > Delete
License… (Licenza > Elimina licenza…) or click Delete (Elimina) in the toolbar, then confirm.

### Find a license

Type in the search field at the top of the sidebar, "Name or vendor" (Nome o produttore). The
list keeps the licenses whose product name or vendor contains the text: `acme` finds
`Acme Editor`, `zzz` finds nothing.

### Copy a serial

Select a license. The serial is hidden by default: click the eye button next to it (its tooltip
reads Show Serial, Mostra seriale) to read it, or press `Cmd+Shift+R` (License > Show or Hide
Serial, Mostra o nascondi seriale). To copy it, click Copy (Copia) or press `Cmd+Shift+C`
(License > Copy Serial, Copia seriale).

The copied serial is removed from the clipboard after the delay chosen in Settings (Impostazioni) > Clear
Clipboard (Svuota appunti): After 30 Seconds (Dopo 30 secondi), After 1 Minute (Dopo 1 minuto,
the default), After 2 Minutes (Dopo 2 minuti) or Never (Mai). The app clears the clipboard
only if it still holds that serial: anything you copy afterwards is left alone.

If a license shows "The serial for this license is missing from the Keychain." (Il seriale di
questa licenza non è nel Portachiavi.), its entry exists but this Mac's Keychain has no serial
for it. A license saved without a serial shows the same message. Click Add Serial… (Aggiungi
seriale…) to type it again, or import a backup that contains it and choose Replace (this
overwrites every license already present with its backup copy).

### Back up your licenses

1. Choose File > Export Licenses… (Esporta licenze…) or press `Cmd+Shift+E`. The command is
   disabled while the library is empty.
2. Type a password of at least 12 characters, twice: Password and Confirm
   Password (Conferma password).
3. Click Export… (Esporta…) and choose where to save the file.

The `.smbackup` file holds every license and its serial, encrypted with that password. The
password cannot be recovered: if you forget it, the backup cannot be opened. Keep the file and
the password in separate places, for example the file on an external disk and the password in
your password manager.

### Restore a backup

1. Choose File > Import Licenses… (Importa licenze…) or press `Cmd+Shift+I`. It works with an
   empty library too.
2. Choose the `.smbackup` file and type its password, then click Import (Importa).
3. If some licenses in the backup are already in SerialManager, choose for Existing Licenses
   (Licenze già presenti): Skip (Salta) keeps yours as they are, Replace (Sostituisci)
   overwrites them with the backup. Then click Import (Importa).
4. The summary shows how many licenses were Imported (Importate), Replaced (Sostituite) and
   Skipped (Saltate).

Clicking Cancel (Annulla) at any point before the last Import (Importa) writes nothing.

A wrong password ("The password is incorrect.", La password non è corretta.), a file that is not
a SerialManager backup, or a backup made by a newer version of the app changes nothing. If an
error stops the import part way, the licenses imported or replaced before it stay, and the message
says how many.

### Moving to another Mac

**Copying the database to another Mac moves your licenses but not their serials: to move the
serials, use the encrypted export.**

In the installed (Release) app the license entries live in the database files in
`~/Library/Application Support/<bundle id>/` (`Licenses.store` and the files next to it), but
the serials live in this Mac's Keychain, as items that do not migrate to a new device and are
not synced. A copied database therefore shows every license with the "missing from the
Keychain" message.

The encrypted export is the only supported way to move the serials:

1. On the old Mac, export a backup (see Back up your licenses).
2. Move the `.smbackup` file to the new Mac.
3. Install SerialManager on the new Mac (see Install).
4. Import the backup with its password (see Restore a backup).

## Build

```bash
tuist generate --no-open
xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -destination 'platform=macOS' build
```

Run the tests the way CI does (signing disabled, see `docs/ci.md`):

```bash
xcodebuild test -workspace SerialManager.xcworkspace -scheme SerialManager -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

The Xcode project is generated by Tuist and is not committed: edit `Project.swift`, then run `tuist generate`.

## License

No license. All rights reserved.
