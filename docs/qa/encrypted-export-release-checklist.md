# Release checklist: encrypted export (#9)

Optional manual check for SPEC `docs/specs/0009-encrypted-export.md` R13 (A9) and the user-visible part of R1, R4, R5, R6 and R10 on a signed Release build (D4). Only the owner runs it. No agent runs it. About 10 minutes. Labels are given in English, with the Italian UI text in brackets.

## Warning: real data, real backup

A Release build opens your real library and your real Keychain. Touch only the entries named "Acme …" created below, and never type a real serial.

The backup holds your WHOLE library, real serials included. Encrypt it with a throwaway password of your choice: at least 12 characters, used nowhere else, never written in this repository (called P below). Save the file only in `~/Desktop/SM-export-check/` (outside the repository), never commit, share or sync it, and delete it in the clean-up section.

Fake values: `Acme Editor` with serial `ACME-0000-TEST-0000`, `Acme Viewer` with no serial, vendor `Acme`, email `user@example.com`. The passwords `short-pass`, `sample-backup-pass` and `sample-backup-paSS` are only for the R6 steps, where nothing is exported.

## Before you start

- [ ] Quit every running SerialManager, a Debug run from Xcode included.
- [ ] Build a signed Release app (`docs/adr/0003-keychain-implementation.md`): `tuist generate --no-open`, then `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release -destination 'platform=macOS' -derivedDataPath build/release -allowProvisioningUpdates build`
- [ ] Open `build/release/Build/Products/Release/SerialManager.app`.
- [ ] Type `Acme` in the sidebar search: no result. If an "Acme" entry exists, run the clean-up first. Clear the search.
- [ ] Note N, the number of licenses in the sidebar. Optional: note M, how many of them show "The serial for this license is missing from the Keychain." [Il seriale di questa licenza non è nel Portachiavi.].
- [ ] In Terminal: `mkdir -p ~/Desktop/SM-export-check`

## Setup: two fake entries

- [ ] Cmd+N, Product Name `Acme Editor`, Vendor `Acme`, Serial `ACME-0000-TEST-0000`, Registered Email `user@example.com`, Save [Salva].
- [ ] Cmd+N, Product Name `Acme Viewer`, Vendor `Acme`, Serial empty, Save. Select it: the detail says "The serial for this license is missing from the Keychain." [Il seriale di questa licenza non è nel Portachiavi.]

## A9. File menu

- [ ] File > Export Licenses… [Esporta licenze…] is enabled.
- [ ] File > Import Licenses… [Importa licenze…] is disabled, and Cmd+Shift+I does nothing.
- [ ] Only if N was 0: after the clean-up, File > Export Licenses… is disabled. Otherwise this item is not checked by hand (code review of `Sources/AppCommands.swift`).

## R6. Password rule and hint (nothing is exported here)

- [ ] Cmd+Shift+E: the "Export Licenses" [Esporta licenze] sheet opens. The text says the password can't be recovered if you forget it [… se la dimentichi non si può recuperare.]. Under the fields, before you type, the hint reads "Use at least 12 characters." [Usa almeno 12 caratteri.].
- [ ] Password and Confirm Password [Conferma password] `short-pass`: Export… [Esporta…] is disabled, the hint is still shown.
- [ ] `sample-backup-pass` and `sample-backup-paSS`: "The passwords don't match." [Le password non coincidono.] appears, Export… is disabled.
- [ ] `sample-backup-pass` in both: Export… is enabled. Do not click it.

## R1, R4, R5. Export of the library

- [ ] Clear both fields and type P in both. Export…: the save panel proposes `SerialManager Backup <today, YYYY-MM-DD>.smbackup`. Choose `~/Desktop/SM-export-check`, Save. No Keychain dialog appears.
- [ ] The sheet shows a progress indicator, then "Backup Exported" [Backup esportato], "Exported N+2 licenses." [Esportate N+2 licenze.] and "Without a serial in the Keychain: M+1" [Senza seriale nel Portachiavi: M+1] (at least 1 if you did not note M).
- [ ] Show in Finder [Mostra nel Finder]: Finder selects the file. Done [Fine] closes the sheet.
- [ ] In Terminal: `cd ~/Desktop/SM-export-check && ls -l`: exactly one `.smbackup` file. Then `F="$(ls *.smbackup)"`.
- [ ] `xxd -l 16 "$F"` prints `534d 4241 434b 5550 0001 0100 0927 c010  SMBACKUP.....'..` (magic, version 1, PBKDF2, 600,000 iterations, 16-byte salt).
- [ ] `xxd -s 32 -l 1 -p "$F"` prints `01` (AES-256-GCM).
- [ ] `echo $(( 0x$(xxd -s 45 -l 4 -p "$F") + 65 ))` prints the same number as `stat -f %z "$F"`.
- [ ] `grep -c -a -F 'ACME-0000-TEST-0000' "$F"`, then the same with `Acme`, `user@example.com`: each prints `0` (nothing in clear).

## R10 and R9. Same name: cancel, then replace

- [ ] `shasum -a 256 "$F"`: note the hash H1.
- [ ] Cmd+Shift+E, P in both fields, Export…, same folder and same name, Save: macOS asks whether to replace the existing file. Cancel, then Cancel the save panel: the sheet is still on the password fields. `shasum -a 256 "$F"` still prints H1.
- [ ] Export… again, same name, Save, Replace: "Backup Exported" again. `ls` shows one `.smbackup` file, `shasum -a 256 "$F"` differs from H1 (new salt and nonce), `xxd -l 16 "$F"` prints the same line as before.
- [ ] Done.

## Not checked by hand

- Keychain access denied (A5, R8): serials live in the data protection keychain, in the app's own access group (`docs/adr/0003-keychain-implementation.md`), so macOS shows no permission prompt to deny; the only access-denied case is a read while the Mac is locked. Covered by the automated tests: the A5 service test in `Tests/EncryptedBackupServiceTests.swift` (export throws `accessDenied`, no file created, an existing file keeps its bytes) and the `ExportModel` Failed and Try Again test in `Tests/BackupModelTests.swift` ("Keychain access was denied. Try again, or check the Keychain permissions for SerialManager." [L'accesso al Portachiavi è stato negato. Riprova, oppure controlla i permessi del Portachiavi per SerialManager.]).
- The 64 MiB cap (A6, R7) and a failed write (R9): they need a library of more than 64 MB or a failing disk. Covered by `Tests/EncryptedBackupServiceTests.swift`.
- Decrypting the file (A1, A3): the app cannot read a backup until the import (#10). Covered by the round-trip tests in `Tests/EncryptedBackupServiceTests.swift`.

## Clean-up and leftover check

- [ ] Select "Acme Editor", menu License [Licenza] > Delete License… [Elimina licenza…], Delete [Elimina]. Same for "Acme Viewer".
- [ ] Quit and reopen the app, search `Acme`: no result. The sidebar shows N licenses again.
- [ ] In Terminal: `rm ~/Desktop/SM-export-check/*.smbackup && rmdir ~/Desktop/SM-export-check`. If a Time Machine backup ran meanwhile, the encrypted file is also in it. Forget P: it protects nothing else.
- [ ] Optional: the Keychain Access count for `it.stefer.SerialManager` equals the one before you started.
- [ ] Clear the search field and quit the app.

Result: write down the date, the commit (`git rev-parse --short HEAD`) and any step that failed, with what you saw. Never write P in the result.
