# AGENTS.md

Guidance for AI coding agents working in the **Wrapybara** repository.

## What Wrapybara Is

Wrapybara turns a website into a real macOS app — its own icon, bundle identifier,
login session, menu bar, native tabs, find bar, downloads, Handoff and Dock badge —
and lets you customise the site inside it with **Boosts** (colours, type, hidden
elements, your own CSS and JavaScript). See `PLAN.md` for the full design and the
engine evaluation; `README.md` for the user view.

## Tech Stack

- **Language:** Swift (Swift 5 language mode — `SWIFT_VERSION = 5.0`).
- **UI:** SwiftUI for the library, editors and Settings; AppKit for windowing
  (`NSWindow`, `NSToolbar`, native tabs), menus and every alert.
- **Web:** `WKWebView` only. See `PLAN.md §2` for why not Chromium, Gecko or Servo.
- **System APIs:** `WKUserScript` / `WKScriptMessageHandler` (boost injection),
  `WKDownload`, `UNUserNotificationCenter`, `NSUserActivity` (Handoff),
  `DispatchSource` vnode watching, `PropertyListSerialization`, `/usr/bin/codesign`
  via `Process`.
- **Persistence:** JSON under `~/Library/Application Support/Wrapybara/`
  (`library.json`, `Runtime/<uuid>.json`, `Icons/<uuid>.png`); app-level settings in
  `UserDefaults`.
- **Dependencies:** none. Keep it that way.
- **Min target:** macOS 13 (Ventura). **Built with Xcode 16+**
  (file-system-synchronized groups, `NavigationSplitView`, `LabeledContent`).
- **App type:** a regular app with a Dock icon — *not* an `LSUIElement` agent. So are
  the apps it generates; that's the point.

## Build & Run

The Xcode project uses **file-system-synchronized groups**, so new files added under
`Wrapybara/` or `WrapybaraTests/` are picked up automatically — no `project.pbxproj`
edits needed.

```bash
xcodebuild -project Wrapybara.xcodeproj -scheme Wrapybara -configuration Debug build
xcodebuild -project Wrapybara.xcodeproj -scheme Wrapybara -destination 'platform=macOS' test
```

The app icon comes from `media-sources/icon.png`: `python3 Tools/make-appicon.py`
masks it to the macOS squircle on Apple's 824/1024 grid and rewrites the ten
`AppIcon.appiconset` slots plus `docs/icon.png`. Replace the source artwork and re-run
the script — never hand-edit the slot PNGs, and don't drop a full-bleed square into
the appiconset directly (it would sit in the Dock as a hard square among rounded
plates, which is the tell this project exists to avoid).

The script decodes, resamples and re-encodes PNG itself, so it needs no image tooling
installed. It only handles 8-bit non-interlaced RGB/RGBA/grey sources and says so
loudly otherwise — re-export rather than widening the decoder.

## The one structural thing to understand first

**There is one binary with two lives.** `Wrapybara.app/Contents/MacOS/Wrapybara` is
copied byte for byte into every app it builds. `LaunchMode.detect()` reads the
running bundle's `Info.plist`: a `WBWrapIdentifier` key means "site app", its absence
means "builder".

Consequences that will bite you if you forget them:

- **A generated app has no asset catalog.** It gets only the executable, a
  hand-written `Info.plist`, an `.icns` and `wrap.json`. Anything in `Site/` that
  reached for `NSImage(named:)` would get `nil`. Use SF Symbols
  (`NSImage(systemSymbolName:)`) or draw in code.
- **A generated app must not depend on Wrapybara existing.** No paths back to it. To
  reach the builder, look it up by bundle identifier and handle "not installed"
  (`SiteAppDelegate.openWrapybara`).
- **`AppSupport.folderName` is the literal `"Wrapybara"`**, never anything derived
  from `Bundle.main`. Generated apps run this code from a bundle called something
  else and must arrive at the same directory.
- **Anything you add to `Site/` ships inside every wrap.** Anything you add to
  `Builder/` is dead weight there. Keep the split.

## Module Layout

Mirrors `PLAN.md §6`. Keep modules aligned: `Model/`, `Boosts/`, `Store/`, `Export/`,
`Icons/`, `Site/`, `Builder/`, `Updates/`, `Common/`.

## Conventions

- Follow the Swift API Design Guidelines.
- One type per file; file name matches the primary type. (Exceptions:
  `LibraryModel+Boosts.swift` extends `LibraryModel`; a few small view files carry a
  `private struct` row type used only by that view.)
- Use `// MARK:` to organise sections.
- Avoid force-unwraps outside tests. `Wrap.blankURL` exists so a fallback URL needs
  none.
- **Keep the decidable parts pure.** `BoostMatcher`, `BoostCSSGenerator`,
  `NavigationPolicy`, `BadgeFromTitle`, `AppNameSanitizer`,
  `BundleIdentifierGenerator`, `InfoPlistBuilder`, `SiteMarkupParser`,
  `URLNormalizer` and `IconCandidate.ranked` take values and return values. That's
  what makes the whole feature set testable without a web view, and it is the single
  most important convention here. Don't reach for `NSWorkspace` or `Bundle.main` from
  any of them.
- Every stored type decodes through `KeyedDecodingContainer.value(_:or:)` /
  `.optional(_:)` rather than a synthesized `init(from:)`. A wrap config is a file on
  disk *and* a copy baked into every generated app; a decoder that throws on a new
  key would orphan every app the previous version built. When you add a property,
  add a decode line with a default.

## Critical Constraints

- **Signing is not optional.** A bundle's signature seals its `Info.plist`; the
  exporter writes a new one, so the copied binary must be re-signed or macOS will
  refuse to execute it on Apple Silicon. Never add a code path that produces an
  unsigned bundle "for now".
- **Never set `LSFileQuarantineEnabled` on Wrapybara.** It would quarantine every app
  Wrapybara writes, and Gatekeeper would block them all.
- **Strip inherited quarantine** from the copied runtime before signing
  (`ExtendedAttributes`). `FileManager` copies extended attributes, and a Wrapybara
  that was opened via right-click → Open still carries `com.apple.quarantine`.
- **`Wrap.bundleIdentifier` is immutable once set.** It keys the app's cookies, its
  `UserDefaults`, its WebKit data directory and its Notification Center permission.
  Changing it signs the user out of their own app.
- **Redirects must never leave the app.** `NavigationPolicy` sends only
  *user-initiated* navigation outside the wrap to the browser. A login flow that
  bounces through an identity provider arrives as `.other`; treating that as
  user-initiated breaks sign-in on real sites.
- **An imported boost's JavaScript starts untrusted, and export clears the flag.**
  A boost file's script would run inside the user's authenticated session. `Boost`'s
  decoder defaults `isJavaScriptTrusted` to `false` on purpose — don't "fix" the
  asymmetry with the memberwise initializer's `true`.
- **Values that don't parse are dropped, not escaped.** A colour that isn't a colour
  emits no declaration; a zap selector with a brace is discarded. Escaping it would
  produce something that no longer selects what the user picked.
- **Watch the directory, not the file.** Configurations are written atomically, which
  replaces the inode; a vnode source on the file goes deaf after one save.

## Testing Notes

- Web views, windows, `codesign` and the network need a real session and are not
  unit-tested. Everything listed under "keep the decidable parts pure" is, and
  thoroughly — that's the deal.
- `JSONFileStore` encodes dates as ISO-8601, which has no sub-second component, so a
  `Date()` from the clock is not equal to itself after a round trip. Use a
  whole-second date in Codable tests (`CodableModelTests.fixedDate`).
- `BoostMatcher` caches compiled expressions across calls; call
  `BoostMatcher.clearCache()` in `setUp`.
- Manually verify: building into `/Applications` and `~/Applications`; a wrap of a
  site with SSO on another domain; a `target="_blank"` link; a PDF download; ⌘F, ⌘T,
  ⌘L, ⌘P; quitting and reopening (session restore); editing a boost while the built
  app is running; the element picker on a single-page app; a wrap built by an older
  version (the rebuild prompt); a streaming page (e.g. a chat) that keeps updating
  while its window is covered or miniaturised.

## Do / Don't

- **Do** update `PLAN.md` when the design changes, and `AGENTS.md` when a constraint
  above stops being true.
- **Do** state a trade-off in the UI when there is one. The aggressive colour reach
  says what it will break, next to the switch. That's the house style: honest about
  heuristics rather than quietly wrong.
- **Don't** add dependencies. Not for HTML parsing (`SiteMarkupParser` deliberately
  scans rather than parses — loading a fetched page into a `WKWebView` to read its
  icon URL would mean *executing* it), not for JSON, not for icons.
- **Don't** grow a browser. No omnibox, no history UI, no bookmarks, no extensions.
  A wrap that becomes a bad browser has failed.
- **Don't** put the injected JavaScript in `.js` resource files. It lives in Swift
  raw-string literals in `BoostScripts` because `AppBundleWriter` copies only the
  executable — a resource would have to be copied too and kept in step.
- **Don't** commit signing credentials or provisioning profiles.
