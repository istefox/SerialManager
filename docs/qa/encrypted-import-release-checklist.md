# Release checklist: encrypted import (#10)

> **Status (2026-11-23): accepted without execution.** This checklist was not run on a Release build. QA checked the flows on fake data in the Debug build; the owner accepted the remaining gap on Release and macOS 14 (see PROJECT_BRIEF.md, Status). The boxes below stay unchecked on purpose.

Manual check for SPEC `docs/specs/0010-encrypted-import.md` R14 (A14) and the user-visible part of R1, R4, R7, R8, R9 and R17 on a signed Release build (D6). Only the owner runs it. No agent runs it. About 20 minutes. Labels in English, Italian UI text in brackets.

## Why a separate macOS user

A14 needs an empty library (the new-Mac case). Your own account holds your real library and Keychain, so everything below runs in a throwaway macOS user account: its library and Keychain start empty and your real data is never opened, exported or touched. Only fake values are used: `Acme Editor` (serial `ACME-0000-TEST-0000`), `Acme Viewer` (no serial), vendor `Acme`, email `user@example.com`. The backup password is the fake `sample-backup-pass`; the wrong one is `sample-backup-paSS`.

## Before you start (your own account)

- [ ] Quit every running SerialManager, a Debug run from Xcode included.
- [ ] Build a signed Release app (`docs/adr/0003-keychain-implementation.md`): `tuist generate --no-open`, then `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release -destination 'platform=macOS' -derivedDataPath build/release -allowProvisioningUpdates build`
- [ ] `mkdir -p /Users/Shared/SM-import-check && ditto build/release/Build/Products/Release/SerialManager.app /Users/Shared/SM-import-check/SerialManager.app`
- [ ] System Settings > Users & Groups: add a Standard user `SM Import Test`. Log in to it (fast user switching).

## A14. Empty library, Import enabled (test user)

- [ ] Open `/Users/Shared/SM-import-check/SerialManager.app`. The sidebar is empty.
- [ ] File > Import Licenses… [Importa licenze…] is enabled.
- [ ] `mkdir -p ~/Desktop/SM-import-check`
- [ ] Cmd+N: Product Name `Acme Editor`, Vendor `Acme`, Serial `ACME-0000-TEST-0000`, Email `user@example.com`, Save [Salva]. Cmd+N: Product Name `Acme Viewer`, Vendor `Acme`, Serial empty, Save.
- [ ] Select Acme Editor, note its "Created" [Creata] date and time (D1).
- [ ] Cmd+Shift+E, `sample-backup-pass` in both fields, Export… [Esporta…], save as `~/Desktop/SM-import-check/E1.smbackup`. "Backup Exported" [Backup esportato], Done [Fine].
- [ ] Delete both licenses (License [Licenza] > Delete License… [Elimina licenza…]). The sidebar is empty again.
- [ ] Cmd+Shift+I, choose `E1.smbackup`, password `sample-backup-paSS`, Import [Importa]: inline "The password is incorrect." [La password non è corretta.], the password stays in the field, the sidebar is still empty.
- [ ] Fix the password to `sample-backup-pass`, Import: no conflict step; "Import Complete" [Importazione completata], "Imported: 2" [Importate: 2], "Replaced: 0" [Sostituite: 0], "Skipped: 0" [Saltate: 0]. Done.
- [ ] The sidebar lists both. Acme Editor reveals `ACME-0000-TEST-0000` and "Created" equals D1. Acme Viewer says "The serial for this license is missing from the Keychain." [Il seriale di questa licenza non è nel Portachiavi.].

## R1, R4. Bad files change nothing

- [ ] `cd ~/Desktop/SM-import-check && echo hello > not-a-backup.smbackup && head -c 100 E1.smbackup > cut.smbackup && cp E1.smbackup newer.smbackup && printf '\x00\x02' | dd of=newer.smbackup bs=1 seek=8 conv=notrunc`
- [ ] Import `not-a-backup.smbackup` and `cut.smbackup` with `sample-backup-pass`: each shows "This file isn't a valid SerialManager backup." [Questo file non è un backup valido di SerialManager.]. Cancel [Annulla].
- [ ] Import `newer.smbackup`: "This backup was made with a newer version of SerialManager." [Questo backup è stato creato con una versione più recente di SerialManager.]. Cancel.
- [ ] The sidebar still shows the same two licenses, same values.

## R17, R7, R8, R9. Conflicts: Cancel, Skip, Replace

The same flow on fake data was checked by QA in the Debug app (QA verdict on 8f7af8e, re-run on ef7db14). The steps below cover the Release build.

- [ ] Edit Acme Editor: Vendor `Acme Changed`, Serial `ACME-0000-TEST-1111`, Save. Edit Acme Viewer: Serial `ACME-0000-TEST-2222`, Save.
- [ ] Cmd+Shift+I, `E1.smbackup`, `sample-backup-pass`, Import: "Already in SerialManager: 2 of 2 licenses." [Già in SerialManager: 2 licenze su 2.], Skip [Salta] selected. Cancel.
- [ ] Acme Editor still shows `Acme Changed` and reveals `ACME-0000-TEST-1111` (Cancel wrote nothing). Import the same file again: the same 2 conflicts appear.
- [ ] Skip, Import: "Import Complete", Imported 0, Replaced 0, Skipped 2. Acme Editor: `Acme Changed`, `ACME-0000-TEST-1111`, "Created" equals D1. Acme Viewer reveals `ACME-0000-TEST-2222`.
- [ ] Import again, choose Replace [Sostituisci] ("Your current licenses are overwritten with the ones in the backup." [Le licenze attuali vengono sovrascritte con quelle del backup.]), Import: Imported 0, Replaced 2, Skipped 0. The sidebar still has exactly two licenses.
- [ ] Acme Editor: Vendor `Acme`, reveals `ACME-0000-TEST-0000`, "Created" equals D1. Acme Viewer: Vendor `Acme`, still reveals `ACME-0000-TEST-2222` (the backup has no serial for it, so the local one is kept).
- [ ] Quit and reopen the app: same two licenses, same values.

## Not checked by hand

- Keychain failure during the apply (R10, A11): serials live in the data protection keychain, so macOS shows no prompt to deny (same as #9). Covered by `Tests/EncryptedBackupImportTests.swift` (stop after 2 of 5, message with counts, list reloaded) and `ImportModelTests`.
- The other corruptions, the 64 MiB cap, the 600,000 to 10,000,000 iteration bounds, NFC passwords, payload validation (A4 to A7): covered by `Tests/BackupReaderTests.swift` and `Tests/BackupPayloadTests.swift`.
- Closing the sheet while the password is being checked (A16, A17): the check takes a fraction of a second, too short to hit by hand. Covered by the `cancelImport()` tests.
- Your own account: only optional, File > Import Licenses… is enabled there too. Do not import anything into it.

## Clean-up

- [ ] In the test user: quit the app, `rm ~/Desktop/SM-import-check/*.smbackup && rmdir ~/Desktop/SM-import-check`. Log out.
- [ ] In your own account: `rm -r /Users/Shared/SM-import-check`. System Settings > Users & Groups: delete `SM Import Test` and its home folder (its library and Keychain go with it).

Result: write down the date, the commit (`git rev-parse --short HEAD`), the macOS version and any step that failed, with what you saw.
