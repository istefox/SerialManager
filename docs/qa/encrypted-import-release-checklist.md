# Release checklist: encrypted import (#10)

Manual check of what the automated tests cannot reach: on a signed Release build, the import reads a real backup and writes to the real Keychain (SPEC `docs/specs/0010-encrypted-import.md` R14). Only the owner runs it, in their own account. No agent runs it. About 5 minutes. Labels in English, Italian UI text in brackets.

Import into an empty library (A14, the new-Mac case) is covered by the automated tests (`EncryptedBackupImportTests`, A1 and A2), so no separate macOS user is needed.

## Why this is safe with your real library

Every import below uses Skip [Salta]: licenses already in SerialManager stay exactly as they are, dates and serials included (R7, covered by tests). The only license created, deleted and re-imported is the fake `Test Import`.

The backup holds your WHOLE library, real serials included. Encrypt it with a throwaway password of your choice: at least 12 characters, used nowhere else, never written in this repository (called P below). Keep the file on the Desktop only and delete it at the end.

## Steps

- [ ] Quit every running SerialManager, a Debug run from Xcode included.
- [ ] Build a signed Release app: `tuist generate --no-open`, then `xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -configuration Release -destination 'platform=macOS' -derivedDataPath build/release -allowProvisioningUpdates build`. Open `build/release/Build/Products/Release/SerialManager.app`.
- [ ] Cmd+N: Product `Test Import`, Serial `ACME-0000-TEST-0000`, Save [Salva].
- [ ] Cmd+Shift+E, password P in both fields, Export… [Esporta…], save as `~/Desktop/SM-import-check.smbackup`. Done [Fine].
- [ ] Select `Test Import`, License [Licenza] > Delete License… [Elimina licenza…].
- [ ] Cmd+Shift+I, choose the file, type a wrong password, Import [Importa]: "The password is incorrect." [La password non è corretta.]. Nothing changes in the sidebar.
- [ ] Type P, Import: "Already in SerialManager: N of N+1 licenses." [Già presenti in SerialManager: …], Skip selected, Import: "Imported: 1" [Importate: 1], "Replaced: 0", "Skipped: N". Done.
- [ ] `Test Import` is back in the sidebar and reveals `ACME-0000-TEST-0000`. Your other licenses look as before.

## Clean-up

- [ ] Delete `Test Import` (License > Delete License…).
- [ ] `rm ~/Desktop/SM-import-check.smbackup`

## Not checked by hand

- Replace, Cancel at the conflict step, corrupted and newer-version files, the Keychain failing during the import: covered by `EncryptedBackupImportTests`, `BackupReaderTests` and `ImportModelTests`, and by QA in the Debug app (C21 to C23).
- macOS 14.

Result: write down the date, the commit (`git rev-parse --short HEAD`), the macOS version and any step that failed, with what you saw.
