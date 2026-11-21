# Release checklist: license form on persistent data (#6)

Optional manual check for SPEC `docs/specs/license-form.md` R10 (R1 to R5 and R8). Only the owner runs it. No agent runs it. About 10 minutes. Labels are given in English, with the Italian UI text in brackets.

## Warning: this uses your real data

A Release build opens your real library (`~/Library/Application Support/it.stefer.SerialManager/Licenses.store`) and your real Keychain. Use only the fake values below, touch only entries named "Acme …", and finish the clean-up section. Never type a real serial.

Fake values: `Acme Editor`, `Acme Viewer`, vendor `Acme`, serials `ACME-0000-TEST-0000`, `ACME-1111-TEST-1111`, `ACME-2222-TEST-2222`, email `user@example.com`.

## Before you start

- [ ] Quit every running SerialManager, a Debug run from Xcode included.
- [ ] Build a signed Release app (`docs/adr/0003-keychain-implementation.md`): `tuist generate --no-open`, then `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release -destination 'platform=macOS' -derivedDataPath build/release -allowProvisioningUpdates build`
- [ ] Open `build/release/Build/Products/Release/SerialManager.app`.
- [ ] Type `Acme` in the sidebar search: no result. If an "Acme" entry exists, run the clean-up first.
- [ ] Optional: in Keychain Access, Local Items, search `it.stefer.SerialManager` and note the count.

Stop if the window shows "Couldn't Load Licenses" [Impossibile caricare le licenze] or a serial row shows a red error: the library or the signing is wrong, not the form.

## R1. Cmd+N opens a new form

- [ ] With the list loaded, press Cmd+N: the "New License" [Nuova licenza] sheet opens with the cursor in Product Name [Nome prodotto].
- [ ] Cancel [Annulla] with no changes: the sheet closes without asking (R8, new form, no changes).

## R2. Product name is required

- [ ] Cmd+N, Product Name three spaces, Serial `ACME-0000-TEST-0000`, Save [Salva]: the red text "Product name is required." [Il nome del prodotto è obbligatorio.] appears, the sheet stays open, the cursor is back in Product Name.

## R8. Cancel writes nothing (new form)

- [ ] On the same sheet, Cancel: "Discard changes?" [Scartare le modifiche?] appears. Keep Editing [Continua a modificare]: the sheet is still open with what you typed.
- [ ] Cancel, Discard Changes [Scarta modifiche]: the sheet closes, and searching `Acme` finds nothing.

## R3. A new license is stored with its serial

- [ ] Cmd+N, Product Name ` Acme Editor ` (a space before and after), Vendor `Acme`, Version `3.0`, Serial `ACME-0000-TEST-0000`, Registered Email `user@example.com`, Save: the sheet closes and "Acme Editor" is in the list.
- [ ] Select it: Name reads "Acme Editor" without spaces. Show Serial [Mostra seriale]: `ACME-0000-TEST-0000`.
- [ ] Quit (Cmd+Q) and reopen the app: the entry and its serial are still there.

## R8. Cancel writes nothing (edit)

- [ ] Select "Acme Editor", Cmd+E, Cancel with no changes: the sheet closes without asking.
- [ ] Cmd+E, Notes `Discard me`, Cancel, Discard Changes: no Notes section in the detail, "Modified" [Modificata il] unchanged. Quit and reopen: still no notes.

## R4. Editing updates the record and its serial

- [ ] Note the "Modified" time and wait one minute. Cmd+E, Version `4.0`, Serial `ACME-1111-TEST-1111`, Save: Version 4.0, Show Serial gives `ACME-1111-TEST-1111`, "Modified" is later.
- [ ] Cmd+E, clear Serial, Save: the detail says "The serial for this license is missing from the Keychain." [Il seriale di questa licenza non è nel Portachiavi.]
- [ ] Quit and reopen: Version 4.0, serial still missing.
- [ ] Add Serial… [Aggiungi seriale…], Serial `ACME-0000-TEST-0000`, Save: Show Serial gives `ACME-0000-TEST-0000`.

## R5. Delete asks for confirmation

- [ ] Cmd+E, Delete License… [Elimina licenza…]: the dialog reads Delete "Acme Editor"? and "This also removes its serial from the Keychain. This can't be undone." Cancel: the sheet is still open. Cancel the sheet: the entry and its serial are still there.
- [ ] In the main window, menu License [Licenza] > Delete License…, Cancel: the entry is still there.
- [ ] Cmd+E, Delete License…, Delete [Elimina]: the sheet closes and "Acme Editor" is gone. Quit and reopen: still gone.
- [ ] Cmd+N, Product Name `Acme Viewer`, Serial `ACME-2222-TEST-2222`, Save. Select it, menu License > Delete License…, Delete: the entry is gone.

## R6 and R7: not checked by hand

A failed save (R6) and a failed delete from the form with the "Couldn't Delete the License" [Impossibile eliminare la licenza] alert (R7) need the Keychain or SwiftData to fail on demand. A Release build has no safe way to do that on your real data, so both are covered by the automated tests (`Tests/LicenseFormIntegrationTests.swift`, `Tests/LicenseFormModelTests.swift`) and code review (SPEC v1.1, Q1).

## Clean-up and leftover check

- [ ] Search `Acme`: for every result, select it, menu License > Delete License…, Delete.
- [ ] Quit and reopen the app, search `Acme`: no result.
- [ ] Optional: the Keychain Access count for `it.stefer.SerialManager` equals the one noted at the start.
- [ ] Clear the search field and quit the app.

Result: write down the date, the commit (`git rev-parse --short HEAD`) and any step that failed, with what you saw.
