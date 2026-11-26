# SPEC 0030: Optional website per license, favicon as sidebar icon

- Version: v1
- Date: 2026-11-26
- Status: implemented, awaiting review (Kanban card SM-WEB-01)
- Related: `docs/specs/license-model.md`, `docs/specs/license-form.md`, `docs/design/gui.md`,
  `docs/adr/0001-storage.md`, `docs/adr/0002-backup-format.md` (sections 6 and 7)

## Goal

A license can carry the homepage of its product. The sidebar row shows that site's favicon, so the
list is easier to scan. Everything else stays as it was.

## Decisions

- D1: `License.website: String`, `""` means unset. Declared with a `= ""` default so SwiftData's
  lightweight migration opens a store written before the field. `private(set)` like the other
  fields, written only by `init`, `update` and `restore`. Carried by `LicenseSummary`,
  `LicenseDraft`, the repository mapping and the fakes. The model rules of the license model SPEC
  (R3 to R5) are unchanged: the model stores the value as given, normalization is `WebsiteURL`.
- D2: normalization (`WebsiteURL.normalize`): trim; empty gives `""`; a scheme is detected only at
  the start of the string (`^[A-Za-z][A-Za-z0-9+.-]*:`), and a dotted host followed by `:port` is
  not a scheme; with no scheme prepend `https://` (so `example.com/help?source=https://example.net`
  gets `https://` and `mailto:123` is refused); accept only `http` and `https` with a non-empty host and no whitespace. Otherwise
  the form shows an inline message and Save is disabled, and `LicenseFormModel.save` refuses.
  The stored value is the normalized string ("example.com" gives "https://example.com"; "ftp://x"
  and "not a url with spaces" are invalid). After a save the form shows the stored value.
- D3: backup. `website` is an optional key of a backup entry: export always writes it, import
  decodes an absent key as `""`. No format version bump (precedent: `registeredName`). ADR 0002,
  sections 6 and 7, record it. Import does not re-validate the string.
- D4: the favicon is fetched directly from the license's own site, with no third-party service.
  Ephemeral `URLSession` (no cookies, no URL cache), 10 s timeouts, HTML capped at 1 MB, icon at
  512 KB. Order: `<link rel>` `icon`, `shortcut icon`, then `apple-touch-icon` from the homepage
  HTML (relative hrefs resolved against the URL after redirects), then `<origin>/favicon.ico`. Only
  data that decodes as an image (ImageIO) is accepted; a candidate that does not decode is skipped.
  At most four candidates are tried.
  - Own-site boundary: only the license's host and its `www.`/bare variant (`example.com` and
    `www.example.com`) are contacted, no CDN or other host. The check runs before every request
    (homepage, each candidate, `/favicon.ico`) and before each redirect is followed (a
    `URLSessionTaskDelegate`); a refused redirect ends that request. A candidate on another host
    is skipped without a request. Redirects inside the boundary, including `http` to `https`,
    are followed.
  - Decode: before anything is accepted or cached, ImageIO decodes a thumbnail of at most 64 px
    (`kCGImageSourceCreateThumbnailFromImageAlways`, with transform), inside the provider and off
    the main actor, from complete data only. What the provider returns and caches (memory and
    disk) is that thumbnail re-encoded as PNG, never the network bytes. Truncated or malformed
    data fails the candidate and the next one, then `/favicon.ico`, is tried. `FaviconIcon` only
    ever receives that PNG.
- D5: `FaviconProvider` is a protocol injected through the SwiftUI environment. The default is
  `NoFaviconProvider`, so previews and tests never touch the network; `InMemoryFaviconProvider` is
  the fake. `WebFaviconProvider` is an actor: concurrent requests for one URL share one fetch;
  successes are cached in memory and on disk (`Caches/<bundle id>/Favicons/`, file name is the
  SHA-256 of the normalized URL, trusted for 7 days); failures are cached in memory for the session
  only. A changed address is a different key.
- D6: `LicenseRow` has a fixed 18 pt leading icon: `key.horizontal` while loading and on any
  failure, the favicon once loaded (`.task(id: website)`). The loaded image is kept with the address
  that produced it and drawn only while that address is current, so editing or clearing the
  address shows `key.horizontal` at once. The row renders at once. Text wrapping
  is unchanged and the icon is `accessibilityHidden`.
- D7: no change to the detail pane, the search scopes or the sort orders. The Web field has its
  own label "Web" and validation message, in English and Italian.
- D8: sample data and tests use only fake addresses (`example.test`) and a stubbed network.

## Acceptance

- A1: a license saved with "example.com" stores "https://example.com", the edit form shows it, and
  it survives closing and reopening an on-disk store.
- A2: clearing the field stores `""`.
- A3: invalid input shows the message and keeps Save disabled.
- A4: a store written by the schema before this change opens with every license and
  `website == ""`.
- A5: a backup round trip keeps `website`; an entry without the key imports as `""`.
- A6: favicon fetching: a relative `<link rel=icon>` is resolved; `/favicon.ico` is the fallback;
  an HTTP error, a timeout or a non-image gives nil; concurrent requests share one fetch; a changed
  address uses a different cache entry; an icon link on another host is skipped and a cross-host
  redirect is not followed, the foreign host is never requested; truncated image data is skipped
  in favour of the next candidate and is never cached; the returned data is a thumbnail of at most
  64 px.

Tests: `Tests/LicenseWebsiteTests.swift`, `Tests/FaviconProviderTests.swift`, with
`Tests/Support/StubURLProtocol.swift`.

## Residue

- The favicon request tells the license's site that this Mac looked at it. It is the owner's own
  list of products and no third party is involved. Per site and per week (the disk cache lifetime)
  that is the homepage request plus up to four icon candidate requests and the `/favicon.ico`
  fallback, all to the site's own host.
- SVG icons are not accepted (ImageIO does not decode them); the next candidate is tried.
- Older builds ignore `website` on backup import and drop it on re-export.
