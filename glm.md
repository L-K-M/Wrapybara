# Wrapybara — comprehensive review (glm.md)

A full read of every Swift file in the repo (~10k lines), focused on bugs, performance,
missing features, visual/layout issues, UX polish, and ideas worth stealing. Written as
a shovel-ready backlog: each entry names the file(s) involved and what to do about it.

**Legend:** 🐛 bug · ⚡ performance · 🎨 visual/layout · ✨ feature · 💡 idea
**Priority:** P1 (should fix soon) · P2 (worth doing) · P3 (nice / later)

---

## 1. Bugs

### 1.1 🐛 P1 — "Zap an Element…" in a *generated app* silently discards the pick
`SiteMenuBuilder` adds **Zap an Element…** to the App menu and the View menu of every
generated app. The picker runs fine, but `SiteWindowController.onPickedSelector` is
only ever set by the boost editor's preview (`LibraryModel.beginPickingElement`).
`SiteAppDelegate` never sets it, so in a site app the picked selector arrives at
`didPickSelector`, calls `onPickedSelector?(selector)` — which is `nil` — and the
user's choice evaporates. No feedback, nothing saved.
**Fix:** remove the two menu items from site apps (they only work in Wrapybara's
preview), or route the pick somewhere useful (open Wrapybara with the wrap and a
pending zap). Removing is the honest minimal fix.

### 1.2 🐛 P1 — Developer ID signing uses `--timestamp=none`
`CodeSigner.sign` always passes `--timestamp=none`. That flag is correct for ad-hoc
signing (an ad-hoc signature cannot carry a timestamp), but for a real Developer ID
Application certificate a secure timestamp is expected — notarization requires one,
and Gatekeeper treats timestamped signatures more favourably. The Settings UI promises
"signed with your Developer ID … won't trip Gatekeeper", which the current flag
undercuts.
**Fix:** pass `--timestamp=none` only when `identity == adHocIdentity`.

### 1.3 🐛 P1 — a restored session gets the *home page's* boosts, not the restored page's
`SiteWebController.restore(interactionState:)` calls `installBoosts(for: wrap.homeURL)`
before restoring the back-forward state. If the app reopens on a deep link whose
URL-scoped boosts differ from the home page's, the wrong stylesheet is applied and the
wrong boost JavaScript set installed — and because `boostedURL` is already set to the
home URL, nothing re-runs until the next navigation.
**Fix:** in `webView(_:didFinish:)`, if `boostedURL != webView.url`, re-install for the
real URL and re-apply the stylesheet (documentStart scripts are already missed for that
first paint, but late is far better than wrong).

### 1.4 🐛 P1 — `WrapBehavior.blocksThirdPartyCookies` is dead code
The property is declared, initialized, coded and serialized in every configuration —
and referenced by *nothing*: not `SiteWebViewFactory`, not the Behaviour editor, not a
single test. It's a phantom knob that misleads readers (and every stored config) into
thinking third-party-cookie blocking is configurable.
**Fix:** remove the property (its CodingKeys line, decode line, and init parameter).
Decoding an older config that contains the key is harmless — unknown keys are ignored.
(If the feature is wanted instead, wire it into `WKWebsiteDataStore`
`httpCookieStore` policy — but note modern WebKit already blocks third-party cookies
by default.)

### 1.5 🐛 P1 — two wraps can end up with the same `.app` file name
`WrapEditorView.commitName` writes the typed name with no uniqueness check. Rename
wrap B to the same display name as wrap A and both builds write the same
`<Name>.app`, silently clobbering each other (`installedAppPath` is stored per wrap,
so the library happily shows both as "Built").
**Fix:** uniquify on commit exactly like creation does
(`AppNameSanitizer.uniqueFileName(avoiding: library.usedAppFileNames)` minus this
wrap). Also worth flagging in the UI when a rename will orphan the previously built
app (the old `.app` is left behind at the old name).

### 1.6 🐛 P2 — the site app's Settings window goes stale
`SiteAppDelegate.showSettings` builds `SiteSettingsWindowController` once with the
configuration *at that moment*. When `reloadConfiguration()` swaps in a fresh
configuration (a boost edited in Wrapybara), the open Settings window keeps showing
the old one.
**Fix:** on reload, rebuild the window's content (or close it so the next ⌘, shows
fresh data).

### 1.7 🐛 P2 — notification clicks route to whichever window happens to be front
`handleNotificationClick(pageID:)` evaluates `notificationClicked(id)` in the front
window's web view. A notification posted by a background window's page activates the
wrong window's page callback (or nothing, if that window was closed).
**Fix:** carry the source window through `NotificationBridge` (id → weak
`SiteWindowController` map) and route the click there, falling back to the front
window.

### 1.8 🐛 P2 — the minus button is a silent no-op for shared boosts
`BoostsTabView`'s footer minus button calls `model.deleteBoost(_:from:)`, which only
removes wrap-local boosts. With a shared boost selected it does nothing — no feedback,
no disable.
**Fix:** disable the button when the selection is a shared boost (delete-everywhere
lives in the context menu), or make it offer that with a confirm.

### 1.9 🐛 P2 — "Delete Everywhere" on a shared boost has no confirmation
`removeSharedBoost(id:)` fires immediately from the context menu and silently switches
the boost off in every wrap using it. Every other destructive action in the app
confirms first.
**Fix:** NSAlert confirm naming the affected wraps.

### 1.10 🐛 P2 — Share picker appears at the bottom-left of the window
`sharePage` calls `picker.show(relativeTo: .zero, of: anchor, …)`. When invoked from
the toolbar, `sender` is an `NSToolbarItem` (not an `NSView`), so the anchor falls
back to the whole content view with a zero rect at its *bottom-left* — the share menu
pops up from the corner of the window rather than near the button.
**Fix:** anchor to `item.view` when the sender is a toolbar item, to the sender view
when it is one, and otherwise to the top of the content view.

### 1.11 🐛 P2 — `URLNormalizer` likely rejects IDN hosts (`bücher.de`)
`URL(string:)` is not an IDNA encoder; non-ASCII hostnames can fail to parse, so
typing a unicode domain into "Wrap a site" rejects a perfectly real site.
**Fix:** detect non-ASCII and pre-encode the host (percent-encoding the host via
`URLComponents` with `percentEncodedHost`, or punycode via `CFStringTransform`).
**Verify first** with the exact macOS 13 Foundation behaviour.

### 1.12 🐛 P2 — every new window opens exactly on top of the last
`SiteWindowController.makeWindow` gives every window the *same*
`setFrameAutosaveName("SiteWindow")`. Separate (non-tabbed) windows therefore all
restore to one identical frame and stack — no cascading, and the autosave key is
fought over by every window.
**Fix:** only the first window of a launch should use the autosave name; subsequent
windows should cascade (`window.cascadeTopLeft(from:)`) — or key the name by window
role/ordinal.

### 1.13 🐛 P2 — preview downloads surface in the *builder's* Dock progress
`BoostPreviewController` sets `downloads.completion = .doNothing`, but
`DownloadCoordinator.begin` still `Progress.publish()`es every download — so clicking
a download link in the boost preview drives Wrapybara's own Dock progress indicator
and drops files in `~/Downloads` with no reveal. Surprising for a "preview".
**Fix:** give `DownloadCoordinator` a "quiet" mode (no publish, no Finder reveal, or
cancel outright) and use it for the preview.

### 1.14 🐛 P3 — session state saved only at quit
`saveSession()` runs in `applicationWillTerminate`. A crash (or force-quit, or
logout-timeout) loses everything since launch, which quietly defeats "reopen where I
left off" for exactly the sessions that mattered.
**Fix:** autosave debounced off `onPageChanged` (e.g. every 5 s after a change).

### 1.15 🐛 P3 — find is hard-wired case-insensitive
`FindBarController.find` sets `configuration.caseSensitive = false` always. Safari
offers an "Aa" match-case toggle in the field's context menu.
**Fix:** small toggle (⌥⌘F or a menu in the field).

### 1.16 🐛 P3 — geolocation silently unsupported
WKWebView on macOS provides no geolocation permission UI to embedders; a site that
asks (weather, maps) gets nothing, and the app has no `NSLocationUsageDescription`
either. At minimum this belongs in the docs as a known limitation; a real fix means
implementing the permission prompt through CoreLocation.

### 1.17 🐛 P3 — `NSApp.applicationIconImage` in the site Settings header
`SiteSettingsView` uses `NSApp.applicationIconImage`, which is correct for the running
app's icon — but the header would look better composed at a small size with rounded
corners like the library rows, and it re-renders the full-size icon each time.

---

## 2. Performance

### 2.1 ⚡ P1 — library icons are re-read from disk on *every* SwiftUI render
`LibraryModel.icon(for:)` → `WrapExporter.resolvedIcon(for:)` does
`Data(contentsOf:)` + `NSImage(data:)` on every call, and it's called from the
sidebar's `ForEach` — so every store change (every keystroke in any editor field, every
slider tick) re-decodes PNG files for every row, plus once more in the editor header.
With a dozen wraps this is dozens of disk reads + PNG decodes per keystroke.
**Fix:** `NSCache<NSUUID, NSImage>` in `WrapExporter` keyed by wrap id and
invalidated by `updatedAt` (or file modification date). One screen of code, big win.

### 2.2 ⚡ P1 — every keystroke in a boost editor writes a JSON file to disk
`updateBoost` → `WrapStore.update` → `didChange(wrapIDs:)` →
`publishRuntimeConfiguration` — a synchronous encode + atomic write of the whole
`WrapConfiguration` per keystroke (the library.json save *is* debounced, but the
runtime publish is not). A running site app then wakes its directory watcher and
re-applies per keystroke too.
**Fix:** debounce the publish together with the library save (one timer, flush both on
terminate; `WrapExporter.build` keeps its immediate publish so a fresh bundle is never
stale).

### 2.3 ⚡ P2 — the boost preview re-applies its whole configuration on every
unrelated state change
`PreviewWebView.updateNSView` calls `model.previewController?.apply(...)` on *every*
SwiftUI update — including `isBuilding` toggles, typing in the wrap *name*, selection
changes anywhere. Each `apply` rebuilds the injector, clears the matcher cache,
re-installs user scripts and evaluates JavaScript.
**Fix:** short-circuit in `BoostPreviewController.apply` when `(wrap, boost)` is
unchanged (both are `Equatable`; compare against the last applied pair).

### 2.4 ⚡ P2 — `refreshStaleRuntimes` freezes the UI for the whole run
Building N stale wraps is N × (binary copy + icon render + `codesign`) all on the main
actor, with only the Build button's spinner as feedback. A dozen wraps ≈ several
seconds of beachball.
**Fix:** at minimum a progress alert ("Rebuilding 3 of 12…"); properly, move the
file/signing work off the main actor (the exporter's inputs are values; the store hop
back to main is one call).

### 2.5 ⚡ P2 — `refreshFromPage` does full work on every KVO tick
`estimatedProgress` fires many times per load; each tick re-derives the title,
represented URL, toolbar label, `NSUserActivity` and Dock badge. Cheap individually,
wasteful in aggregate — and `updateUserActivity` calls `becomeCurrent()` per tick.
**Fix:** diff-and-skip (only act when title/url/flags actually changed), and/or
coalesce the progress ticks.

### 2.6 ⚡ P3 — `SiteIconFetcher` buffers the whole response before its size cap
`fetchData` checks `data.count <= maximumResponseBytes` *after* `session.data(for:)`
returned. A `rel=icon` pointing at a 2 GB file is fully downloaded first.
**Fix:** use `URLSession.bytes(for:)` and stop at the cap, or an `URLSessionDataDelegate`.

### 2.7 ⚡ P3 — `BoostMatcher` cache is cleared on every `apply`
`SiteWebController.apply` calls `BoostMatcher.clearCache()` unconditionally, throwing
away compiled regexes for every open window on every edit. Only a change to the boost
*list* needs it (and `WrapConfiguration` is `Equatable`, so it can be skipped when
unchanged — same guard as 2.3 helps here too).

### 2.8 ⚡ P3 — window controllers are never deallocated until close
Minor: `SiteAppDelegate` keeps a strong `windowControllers` array and removes entries
only on `willCloseNotification`. That's correct, but the notification-based token
dance could simply be `controller.webController` asking its delegate on close. Not a
leak — just fragile plumbing.

---

## 3. Missing features (high value)

### 3.1 ✨ P1 — a real error page for failed navigations
A wrap launched offline shows a blank white window (`report(_:)` only NSLogs).
Safari's "can't open the page … because the server cannot be found" with a **Try
Again** button is the expected behaviour and a ten-line `loadHTMLString` away. This is
the single most user-visible gap in the runtime.

### 3.2 ✨ P1 — loading progress is observed but never shown
`estimatedProgress` is KVO'd and drives nothing. The reload toolbar button should
spin/become Stop while loading (the menu's Stop Loading validates correctly; the
toolbar has no state at all). A thin progress bar under the toolbar (Safari-like) is
the deluxe version; swapping reload⇄stop is the minimum.

### 3.3 ✨ P1 — Dock menu for site apps
Right-clicking a generated app's Dock icon offers only macOS's defaults. A menu with
**New Window**, **Go to Home Page** (and later: recent pages) is a one-delegate-method
feature (`applicationDockMenu`) and exactly the kind of "real app" polish this project
is about.

### 3.4 ✨ P1 — drop/paste a URL on Wrapybara to create a wrap
`BuilderAppDelegate.application(open:)` treats every opened file as a boost import.
Dropping `https://example.com` (dragged from a browser address bar) onto the Dock icon
or the library window should offer to wrap it. The plumbing already exists
(`URLNormalizer`, `makeWrap`); it's a two-branch `if` in the open-urls handler plus a
drop delegate on the sidebar.

### 3.5 ✨ P2 — "Edit in Wrapybara" should land on *this* wrap
`SiteAppDelegate.openWrapybara()` launches the builder but can't say which wrap. The
site app knows its `WBWrapIdentifier`; Wrapybara could accept it (launch argument,
`NSUserActivity`, or a `wrapybara://wrap/<uuid>` URL scheme) and pre-select that row.
Kills the "which of my twelve wraps is this?" hunt.

### 3.6 ✨ P2 — per-wrap storage clearing
Phase 3 in `PLAN.md`. The natural home is the site app's Settings window (it's the
app that owns the session): "Clear cookies and website data" +
"Clear cache". Straight `WKWebsiteDataStore.removeData`.

### 3.7 ✨ P2 — content blocker per wrap (`WKContentRuleList`)
Also Phase 3. A built-in "hide cookie banners / block trackers" rule list per wrap is
the single most-requested wrapper feature that doesn't exist yet, and it slots into
`SiteWebViewFactory` cleanly. Compile-once, inject per wrap, toggle in Behaviour.

### 3.8 ✨ P2 — boost presets gallery
Phase 2. Ship a handful of well-made shared boosts (Dark, Readable, Kill Sticky
Headers, No Cookie Banners, Monospace Everything) as built-ins on the shared shelf.
Cheap to build (they're just `Boost` values), high perceived value, and they teach the
model better than any prose.

### 3.9 ✨ P2 — undo in the boost editor
Phase 2. Every knob writes straight through to the store; there is no ⌘Z anywhere
(the Edit menu's Undo reaches only text fields). An `NSUndoManager` on
`LibraryModel.updateBoost` would cover knobs and zaps uniformly.

### 3.10 ✨ P2 — Save page as PDF / Copy Page Image
`WKWebView.createPDF` / `takeSnapshot` are public API; a File-menu "Export as PDF…"
and "Copy Image of Page" are small, genuinely useful, and very Mac.

### 3.11 ✨ P3 — ⌘L with recent addresses
The Go-to-Address sheet has no history. A short recents list (even 5, from the session
store's back-forward entries) would make it far more usable.

### 3.12 ✨ P3 — PWA-aware wrapping
The fetcher already reads the web app manifest for icons/names; it could also use
`start_url` as the home URL, `display: standalone` to default the chrome to
"title bar only", and `theme_color` for the default window background. Wrapping a real
PWA would then need one click instead of four corrections.

### 3.13 ✨ P3 — duplicate a wrap
Context-menu "Duplicate" (new id, new bundle identifier, " 2" name). The obvious
work/personal second-account path, currently a manual re-entry of everything.

### 3.14 ✨ P3 — library drag-to-reorder
The sidebar has no ordering. `WrapStore` even has a comment noting where the reorder
belongs when it's added. Alphabetical sort toggle would do too.

### 3.15 ✨ P3 — export/import a whole wrap
`.wrapyapp` file = configuration + icon, importable on another Mac. The pieces exist
(boost export/import already does the same dance).

---

## 4. Visual issues & layout

### 4.1 🎨 P2 — transparent-title-bar mode has no top inset handling
With `chrome = .none` (`fullSizeContentView` + transparent title bar), the find bar
slides in at the very top of the window — directly under the traffic lights — and the
page's own top content is obscured by them. Sites with their own header look great;
everything else loses its top 28 pt.
**Fix:** pin the find bar below the safe area, and offer (or default to) a modest
`additionalSafeAreaInsets` for the web view in this mode.

### 4.2 🎨 P2 — icon-only buttons without accessibility labels
The preview status bar and the boosts footer use bare `Image(systemName:)` buttons
with `.help()` tooltips but no `accessibilityLabel`. VoiceOver reads them as "button".
One-line fixes throughout.

### 4.3 🎨 P3 — segmented Picker as the wrap editor's tab control
macOS convention for this shape is a toolbar-based tab (or `TabView` with automatic
style). The segmented control reads slightly "iOS". Consider an `NSToolbar`-backed
titlebar search/tab row — or at least move Site/Behaviour/Boosts into a real toolbar.

### 4.4 🎨 P3 — the address "field" in the site toolbar is a plain label
`addressLabel` is a selectable `NSTextField` label — good (no omnibox creep) — but
there's no affordance that ⌘L/click works, and no lock icon for https. A subtle
"⌘L" hint on hover would teach the shortcut for free.

### 4.5 🎨 P3 — zap picker overlay color is fixed brown
`#8B5A2B` on brown-tinted sites (this project's own brand tint!) can be low
contrast. Compute the highlight from the wrap's `tintHex` complement, or offer
blue/red.

### 4.6 🎨 P3 — Dock badge aggregates nothing (see also 1.7/5.2)
Only the front window's title is parsed. A badge should reflect the maximum unread
count across all windows/tabs — that's what a browser tab strip effectively shows
you.

### 4.7 🎨 P3 — empty shared-boosts section says "None yet" twice
Both sections of the boosts list show "None yet" placeholders when empty; one
well-set empty state ("Shared boosts are switched on per app — import a
`.wrapyboost` file or promote one of yours") would teach the feature.

---

## 5. UX, convenience, delight

### 5.1 💡 P1 — the boost editor needs a debounce/typing feel pass
With 2.1/2.2 fixed, typing CSS stays live everywhere it matters. While there: the CSS
draft's `onAppear` snapshot goes stale if the boost is changed elsewhere (zap picker)
— reconcile drafts on external change or re-derive via `.onChange(of: boost.id)`.

### 5.2 💡 P2 — Dock badge from all windows
Covered in 4.6 — implement `max` across `windowControllers` using
`BadgeFromTitle.count(for:)`, falling back to the front window's bullet marker.

### 5.3 💡 P2 — keyboard shortcuts for boosts
Per-wrap global hotkeys are Phase 4, but *in-app* shortcuts ("⌘1 toggles my Dark
boost") need no system integration: a Boosts submenu with checkable items, wired
through the existing live-config reload, would make toggling a theme instant.

### 5.4 💡 P2 — "What did this boost change?" diff view
Phase 2 item and the best answer to "boosts are magic". A simple two-column
generated-CSS diff (before/after knob values) is enough; no need for a DOM diff.

### 5.5 💡 P2 — multi-select zap
Shift-click several elements in the picker to zap them all (collect selectors, commit
on Enter). Today each pick is a separate round-trip through the editor.

### 5.6 💡 P3 — wrap "health check" in the library
A small diagnostic row: reachable? manifest found? icon quality (≥128px)? SSO hosts
configured? Catches "why does my app look bad" at a glance.

### 5.7 💡 P3 — quirky: Dock badge for *Wrapybara itself* showing stale-runtime count
The builder already computes `staleWrapCount` for the footer — mirror it on the
builder's Dock icon. A wrapper that keeps its own apps fresh is the whole brand.

### 5.8 💡 P3 — quirky: capybara easter egg
The name deserves one: a capybara somewhere tasteful — the "About" art, a
`capybara.wav` on first successful build, or the empty-library illustration. One
smile, no features harmed.

### 5.9 💡 P3 — template gallery ("one-click wraps")
A New Wrap sheet tab with a handful of curated sites (Gmail, Notion, Linear, Figma,
YouTube Music) pre-tuned (UA, extra in-app hosts, chrome). Low effort — they're just
`Wrap` values — and it turns the empty state into a demo.

### 5.10 💡 P3 — per-wrap icon drag-out
Let the library row's icon be draggable (NSPasteboard `NSFilePromises` or just the
PNG) — users assemble their own docs/screenshots.

---

## 6. General / code health

### 6.1 P2 — `SiteWebController.apply` sets `pageZoom`/UA but there's no "requires
reload" hint. Changing the UA live only affects the *next* navigation; sites that
fingerprint at load won't re-evaluate. A one-line "takes effect on next page load"
caption in the Behaviour tab (like the inspector toggle has) would prevent confusion.

### 6.2 P2 — `CodeEditor.disableSmartSubstitutions` writes process-wide UserDefaults
It permanently writes four defaults keys into Wrapybara's domain (they persist across
relaunches and affect every text field in the app, including prose fields like boost
notes). Works, but the documented blast radius is understated: it also affects the
wrap *name* field (an apostrophe typed there won't smart-quote — fine) and is
irreversible from the UI. Prefer setting the keys *at launch* only if a code editor
has ever been used, or revert when the editor closes.

### 6.3 P3 — `WrapStore` has no migration hook. `formatVersion` exists on both
documents but nothing reads it to branch. Fine today (version 1, additive-only
decoding); worth a comment or a switch before version 2 needs one.

### 6.4 P3 — `SiteAppDelegate.isRunningTests` and `BuilderAppDelegate.isRunningTests`
and `UpdateChecker.isRunningTests` are three copies of the same helper. One
`LaunchMode.isRunningTests` (or a tiny `Common/TestSupport.swift`) would do.

### 6.5 P3 — magic strings for handler names/identifiers are centralized
(`BoostScripts.Handler`) — good — but `com.wrapybara.Wrapybara` in
`SiteAppDelegate.openWrapybara` and the tabbing identifiers are literals that should
live next to `InfoPlistBuilder`/`BundleIdentifierGenerator`.

---

## 7. Things that are genuinely good (keep doing)

Collected so a future refactor doesn't flatten them: the pure-and-tested decidable
core; the byte-copy single binary with seed + live config newest-wins; directory
(not file) watching; atomic writes; decode-with-defaults discipline; honest UI about
heuristic restyling; the notification trust model for imported scripts; the find bar
via WebKit's own find; the Smart-Invert-style media counter-filter; the
selector-ladder that rejects framework-generated identifiers.

---

## 8. Implementation queue (what this review will act on now)

High-confidence, small, safe changes, each as its own branch/PR:

1. Icon cache for the library (2.1).
2. Debounced runtime-config publishing (2.2).
3. Remove the broken Zap menu items from site apps (1.1).
4. `--timestamp=none` only for ad-hoc signing (1.2).
5. Install boosts for the restored URL (1.3).
6. Dock badge across all windows (4.6/5.2).
7. Share picker anchoring (1.10).
8. Uniquify renamed wraps (1.5).
9. Remove dead `blocksThirdPartyCookies` (1.4).
10. Skip no-op preview applies (2.3).
11. Site-app Dock menu (3.3).
12. Refresh the stale Settings window (1.6).

Everything else stays in this document and graduates to `ANALYSIS.md`.
