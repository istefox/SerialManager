# CLAUDE.md

## Project

SerialManager - a macOS app to keep track of the serial numbers and license keys of your software.

See PROJECT_BRIEF.md for full context on what to build and why.

## Stack

- Language/runtime: Swift 6, SwiftUI, macOS 14+
- Project type: macOS app (windowed SwiftUI app)
- Tooling: Tuist 4 (project generation), Swift Testing (unit tests), xcodebuild

## Architecture

Single-target SwiftUI app plus a unit test target, defined in `Project.swift`.
Layout: `Sources/` (app code), `Resources/` (assets), `Tests/` (Swift Testing), `docs/` (design notes, ADRs).
Use Observation (`@Observable`, `@Bindable`) and async/await; no `ObservableObject`.
Storage (docs/adr/0001-storage.md): entry metadata in SwiftData, serials in the macOS Keychain keyed by entry UUID, never in the SwiftData store. Backup is an encrypted JSON export.
Keychain access goes behind a protocol; tests use an in-memory fake, never the real Keychain.

## Git conventions

- Workflow: GitHub Flow (short-lived branches off main, merged back via PR or fast-forward)
- Commits: Conventional Commits v1.0.0 (`type(scope): description`)
- Branches: Conventional Branch (`feature/`, `fix/`, `chore/`, `docs/`, `release/`, `hotfix/`)
- Default branch: main. Never commit directly to main. Never force-push.

## Commands

```bash
tuist generate --no-open                                      # regenerate after editing Project.swift
xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -destination 'platform=macOS' build
xcodebuild -workspace SerialManager.xcworkspace -scheme SerialManager -destination 'platform=macOS' test
```

CI: `.github/workflows/ci.yml` runs generate + test on every PR and push to `main` (macOS 26 runner, Xcode 26.6, signing disabled). Tuist version pinned in `mise.toml`. Details and rollback: `docs/ci.md`.

## Working agreements

- Run build and tests before committing.
- Keep commits small and atomic, one logical change each.
- Update PROJECT_BRIEF.md "Status" section when a milestone is reached.
- Never edit the .xcodeproj: it is generated. Change Project.swift and run tuist generate.
- The repository is public: never commit real serial numbers, license keys or personal data, not even in tests or previews. Use obviously fake sample values.
- `.agentsroom/`, `.mcp.json` and `.claude/settings.local.json` are local tool plumbing and stay out of git.
