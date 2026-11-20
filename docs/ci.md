# Continuous integration

Status: in use. Facts checked on 2026-11-19 against the live sources linked below.

## What runs

`.github/workflows/ci.yml` runs on every pull request to `main`, every push to `main`, and on
demand (`workflow_dispatch`). One job, `Build and test`:

1. check out the repository (no persisted credentials);
2. install mise and, through it, the Tuist version pinned in `mise.toml`;
3. `tuist generate --no-open`;
4. `xcodebuild test` on the `SerialManager` scheme, with code signing disabled (Debug);
5. `xcodebuild build -configuration Release` on the same scheme, workspace and DerivedData,
   also unsigned.

Each `xcodebuild` call exits non-zero when a test fails or the build breaks, which fails the
job. The Release step runs only if the tests passed.
The workflow uses no secrets: the token it receives is read-only (`permissions: contents: read`).

The same check locally:

```bash
tuist generate --no-open
xcodebuild test -workspace SerialManager.xcworkspace -scheme SerialManager \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
xcodebuild build -workspace SerialManager.xcworkspace -scheme SerialManager \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

## Decisions

### Release build as well as the tests

`xcodebuild test` compiles the Debug configuration only. Code under `#if DEBUG` / `#else`
differs between the two: `SerialManagerApp.init()` wires the real `LicenseLibrary.makeRepository()`
only in Release, while Debug uses in-memory fakes. Without the Release step a compile error in
that branch would reach `main` unnoticed (plan `docs/plans/0004-license-repository-plan.md`,
P7). The step only compiles: the Release app is not run, signed or uploaded.

It reuses the job's DerivedData, so packages and the module cache are shared, but Release
(whole-module optimisation) recompiles the app sources from scratch. Measured cost: see
"What to watch".

### Runner: `macos-26`, pinned

- Standard GitHub-hosted runners, macOS included, are free for public repositories
  ([billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
  For a private repository macOS costs $0.062 per minute, so the choice of public visibility
  is what keeps this CI free.
- Standard arm64 macOS runner: 3 cores (M1), 7 GB RAM, 14 GB SSD; at most 5 concurrent macOS
  jobs on the Free plan ([runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
  [limits](https://docs.github.com/en/actions/reference/limits)).
- Labels available ([runner-images](https://github.com/actions/runner-images)): `macos-15`,
  `macos-26` (= `macos-latest`), `xcode-27` (preview). macOS 14 images were retired from
  GitHub Actions on 2026-11-02, so no runner matches the macOS 14 deployment target: CI builds
  for macOS 14 but runs the tests on macOS 26.
- The label is `macos-26`, not `macos-latest`, so an image change is a deliberate edit and not a
  surprise on the next run.

### Xcode: 26.6, pinned with `DEVELOPER_DIR`

- The `macos-26` image (version 20261102) ships Xcode 26.0.1 to 26.6, default 26.6
  ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)).
  The readme does not state the bundled Swift version. The Xcode 26 line is the release before
  the Xcode 27 used locally, so Swift 6 language mode and the macOS 14 deployment target are
  expected to build; the `Show toolchain` step prints the exact Xcode and Swift versions, and
  the first run on GitHub is what confirms it. First run (2026-11-19): Xcode 26.6 (17F113),
  Swift 6.3.3, Tuist 4.218.1, 35 tests passed, job time 1 min 30 s.
- Local development currently uses Xcode 27.2. The only image with Xcode 27 is `xcode-27`,
  still in preview. CI therefore compiles with an older SDK than local builds: code that needs
  an API newer than the Xcode 26 SDK fails in CI first. Move to `xcode-27` once it is GA.
- When the image drops Xcode 26.6, the job fails at the first step: update `DEVELOPER_DIR`.

### Tuist: 4.218.1 through mise

- Tuist recommends mise on CI and pinning the version with mise
  ([Tuist CI guide](https://tuist.dev/en/docs/guides/integrations/continuous-integration)).
  Neither mise nor Tuist is preinstalled on the image.
- `mise.toml` at the repository root pins Tuist 4.218.1, the latest stable release on
  2026-11-17 and the version used locally. `jdx/mise-action` runs `mise install`, which reads
  that file; the mise binary itself is pinned in the workflow.
- `tuist generate` needs no Tuist account or token: only the Tuist server features (cache,
  previews) do, and they are not used.

### Actions pinned by commit SHA

`actions/checkout` v7.0.1 and `jdx/mise-action` v5.2.7 are referenced by full commit SHA
with the version in a comment. A moved tag cannot change what runs. Update them by hand.

### Signing: disabled in CI

`Project.swift` sets `DEVELOPMENT_TEAM` and automatic signing for local builds. The runner
has no certificate and the repository must hold none, so both `xcodebuild` steps override
`CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO` and an empty `CODE_SIGN_IDENTITY`.
`Project.swift` is unchanged. The tests do not touch the real Keychain (they use the in-memory
fake), so they need no signed entitlements. Release signing and notarisation are out of scope.

## Protecting `main`

Applied on 2026-11-19, after the first green run (PR #3), with the owner's approval. Branch
protection on `main`:

- required status check `Build and test` (the job name), bound to the GitHub Actions app, so
  no other app can satisfy it;
- branches do not have to be up to date with `main` before merging (`strict: false`), which
  keeps parallel feature branches mergeable without a rebase each time;
- force pushes and deletion of `main` are blocked;
- no required reviews (single maintainer);
- not enforced for admins: the owner can still bypass it in an emergency, for example when
  a runner image change breaks CI.

Renaming the job breaks the rule until the required check is updated. Inspect or change it with
`gh api repos/istefox/SerialManager/branches/main/protection`.

## Rollback

To drop only the Release build, delete the `Build Release` step from `ci.yml` in a pull
request: the job name, and therefore the required check, stay the same.

To remove CI altogether, delete `.github/workflows/ci.yml` (and `mise.toml` if no longer wanted) in a pull request, or
disable the workflow from the Actions tab with no code change. Remove the required check first
(`gh api -X DELETE repos/istefox/SerialManager/branches/main/protection`), otherwise every pull
request stays blocked.

## What to watch

- Run time: about 1 min 30 s on the first run; 2 min 19 s once the Release build was added
  (2026-11-20, PR #8: tests 1 min 23 s, Release build 34 s). The limit is `timeout-minutes: 30`.
  A sudden jump usually means a cache miss or an image change.
- Release step proof (2026-11-20): a type error placed only in the `#else` branch of
  `SerialManagerApp.init()` left the 111 tests green and failed `Build Release`
  ([run 44798342854](https://github.com/istefox/SerialManager/actions/runs/44798342854),
  throwaway branch, never merged).
- Image announcements in [runner-images](https://github.com/actions/runner-images): removal of
  Xcode 26.6, `xcode-27` reaching GA.
