# ADR 0002: Keychain implementation for serials

- Status: accepted
- Date: 2026-11-19
- Refines: ADR 0001, decision 2 (serials in the macOS Keychain)

## Context

ADR 0001 keeps each serial in the Keychain, keyed by the UUID of its license entry, and makes
the encrypted export the only way to move serials between Macs. macOS offers two Keychain
implementations behind the same SecItem API, and they do not honour the same attributes.

Sources, retrieved on 2026-11-19 from developer.apple.com:

- TN3137 "On Mac keychain APIs and implementations": SecItem "defaults to targeting the
  file-based keychain. To target the data protection keychain, set the
  `kSecUseDataProtectionKeychain` attribute [...] to true"; "The file-based keychain is on the
  road to deprecation"; data protection access groups come from code signing entitlements that
  "must be authorized by a provisioning profile"; the `security` command-line tool "is primarily
  focused on the file-based keychain".
  https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- `kSecUseDataProtectionKeychain` (macOS 10.15+): needed when adding, searching or deleting an
  item "to which the `kSecAttrAccessible` or `kSecAttrAccessGroup` attributes apply".
  https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: "Items with this attribute do not migrate to a
  new device."
  https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
- `kSecAttrSynchronizable`: when absent or false, "no synchronizable items are added or returned".
  https://developer.apple.com/documentation/security/ksecattrsynchronizable
- `errSecMissingEntitlement` and "Sharing access to keychain items among a collection of apps":
  the app's access groups come from `keychain-access-groups` and the application identifier;
  the team-prefixed app ID is the app's default access group.
  https://developer.apple.com/documentation/security/errsecmissingentitlement
  https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

Observed on 2026-11-19 at commit `61dd579`: Tuist generated `CODE_SIGN_IDENTITY = "-"`, so the
app was ad-hoc signed, with no team identifier, no application identifier and no provisioning
profile. Such an app has no data protection access group.

## Decision

1. **Use the data protection keychain.** It is the only implementation that honours a
   `ThisDeviceOnly` accessibility class, which is what makes an item device-local as ADR 0001
   requires, and it is Apple's recommended target.
2. **Item attributes.** Every serial is one generic password item:

   | Key | Value |
   |-----|-------|
   | `kSecClass` | `kSecClassGenericPassword` |
   | `kSecAttrService` | bundle identifier `it.stefer.SerialManager` (injectable) |
   | `kSecAttrAccount` | license UUID string |
   | `kSecUseDataProtectionKeychain` | `true`, on add, update, copy and delete |
   | `kSecAttrSynchronizable` | `false`, on every call |
   | `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, on add |
   | `kSecValueData` | UTF-8 bytes of the serial, stored as given |

   No `kSecAttrAccessGroup` is set: items land in the app's default, private access group.
3. **Signing.** The app target is signed with the Apple Development identity of team
   T7H24G7BFW and carries `keychain-access-groups = [$(AppIdentifierPrefix)it.stefer.SerialManager]`
   (`Project.swift`). On 2026-11-19 `xcodebuild -allowProvisioningUpdates` resolved this with the
   team's wildcard "Mac Team Provisioning Profile: *" (application identifier and access group
   `T7H24G7BFW.*`), which authorizes the app's group; the signed app carries
   `com.apple.application-identifier = T7H24G7BFW.it.stefer.SerialManager`. The test target is
   unchanged.

## Consequences

- Serials never sync to iCloud and do not migrate with Migration Assistant; the encrypted
  export stays the only way to move them (ADR 0001, decision 3).
- Builds need the team's development certificate and a profile. The first build on a Mac may
  need `-allowProvisioningUpdates` or one build from Xcode; later builds use the cached profile.
- CI (ticket #12) must build and test with signing disabled (`CODE_SIGNING_ALLOWED=NO`). Unit
  tests never touch the real Keychain, so they do not need the entitlement.
- An unsigned or ad-hoc signed build gets `errSecMissingEntitlement` (-34018) from every
  SecItem call; it surfaces as `SerialStoreError.unexpected`, not as access denied, because it is
  a build defect.
- The `security` tool cannot be used to inspect these items. Verification uses the Debug-only
  `--keychain-smoke-check` harness inside the signed app and Keychain Access ("Local Items").
- With `WhenUnlocked`, a read while the Mac is locked fails with `errSecInteractionNotAllowed`,
  reported as access denied. Acceptable: reads are user-driven.

## Alternatives considered

- **File-based (login) keychain**: no signing change and `security` works, but
  `kSecAttrAccessible` does not apply, the item lives in a keychain file that Migration
  Assistant can carry to a new Mac, Apple calls it on the road to deprecation, and an ad-hoc
  signature that changes on every build is expected to trigger a Keychain prompt after each
  rebuild in development.
- **Explicit App ID with a dedicated profile**: equivalent for this app; the team wildcard
  profile already authorizes the app's own group, so no extra App ID is required today.
