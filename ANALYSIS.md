# ANALYSIS.md — Wrapybara backlog

Shovel-ready findings from the full reviews of the codebase (~10k lines of Swift,
every module), maintained as the pick-up list for future work. Each entry says
what's wrong (or missing), why it matters, where it lives, and how to fix it. When
you finish an entry, delete it — that's the deal.

Priorities: **P1** should fix soon · **P2** worth doing · **P3** nice / later.
Types: 🐛 bug · ⚡ performance · 🎨 visual/layout · ✨ feature · 💡 idea.

Related documents: `PLAN.md` (design), `AGENTS.md` (constraints — read before touching
export/signing/boost trust), `glm.md` (the first review), `k3.md` (the second review,
whose remaining findings live here and whose implemented findings are in flight below).

---

## In flight — open PRs, reviewed and waiting (do not duplicate)

The twenty-three changes that came out of the glm and k3 reviews have been reviewed
and merged, except one. What is still open:

| PR | Branch | State |
| --- | --- | --- |
| [#16](https://github.com/L-K-M/Wrapybara/pull/16) | `fix/bare-key-shortcuts` | **Not merged — premise refuted.** See "the ⌘N/⌘B shortcuts were never bare keys" below. |

`#2`–`#15` and `#17`–`#24` are on `main`.

---

## Bugs

### 🐛 P3 — the ⌘N/⌘B shortcuts were never bare keys
`ANALYSIS.md` and [#16](https://github.com/L-K-M/Wrapybara/pull/16) both claimed
`LibraryView.swift`'s `.keyboardShortcut("n")` and `WrapEditorView.swift`'s
`.keyboardShortcut("b")` fired on ordinary typing. They don't: SwiftUI's
`keyboardShortcut(_:modifiers:)` declares `modifiers: EventModifiers = .command`, so
those are **⌘N** and **⌘B**. The bug did not exist, and #16's diff would have deleted
a working ⌘B and swapped the app's only ⌘N for Return. **If there's still something
worth doing here** it's the opposite shape: give the builder a
`CommandGroup(replacing: .newItem)` so ⌘N is a real menu command that works from the
populated library too, and add `.keyboardShortcut(.defaultAction)` to the empty-state
button *alongside* its ⌘N rather than instead of it.

### 🎨 P3 — an "everywhere" boost restyles the navigation error page
With [#5](https://github.com/L-K-M/Wrapybara/pull/5) and
[#24](https://github.com/L-K-M/Wrapybara/pull/24) both landed, the two interact:
`didFail` strips the user scripts and loads the error page, then #5's new `didFinish`
hook sees `boostedURL != webView.url` (it's `about:blank` now) and calls
`installBoosts(for:)` + `reapplyStylesheet(for:)`. A boost scoped to *everywhere* —
the Dark preset, say — therefore repaints the recovery screen #24 deliberately left
unstyled. Cosmetic, never a crash, and the Try Again link keeps working. **Fix:** skip
the `didFinish` re-install when the URL is `about:blank`, the same carve-out #24
already makes in `decidePolicyFor`.

### 🐛 P2 — notification clicks route to whichever window is front
`SiteAppDelegate.handleNotificationClick(pageID:)` evaluates
`notificationClicked(id)` in the **front** window's web view. A notification posted by
a background window's page activates the wrong window's callback (or nothing, if that
window was closed). **Fix:** carry the source window through `NotificationBridge`
(id → weak `SiteWindowController` map, populated in the `onNotification` closure the
app delegate already installs per controller) and route the click there, falling back
to the front window. *Note: #6, #12, #13 and #15 have landed, so
`SiteAppDelegate` is clear for this.*

### 🐛 P2 — the minus button is a silent no-op for shared boosts
`BoostsTabView`'s footer minus button calls `model.deleteBoost(_:from:)`, which only
removes wrap-local boosts. With a shared boost selected it does nothing — no feedback,
no disable. **Fix:** disable it when the selection is shared (delete-everywhere lives
in the context menu), or make it offer that with a confirm.

### 🐛 P2 — "Delete Everywhere" on a shared boost has no confirmation
`removeSharedBoost(id:)` fires immediately from the context menu and silently switches
the boost off in every wrap using it. Every other destructive action in the app
confirms first. **Fix:** NSAlert confirm naming the affected wraps
(`store.wrapIDsUsing(sharedBoostID:)` already returns them).

### 🐛 P2 — `URLNormalizer` likely rejects IDN hosts (`bücher.de`)
`URLNormalizer.url(from:)` relies on `URL(string:)`, which is not an IDNA encoder;
non-ASCII hostnames can fail to parse, so typing a unicode domain into "Wrap a site"
rejects a real site. **Fix:** detect non-ASCII in the host part and pre-encode
(percent-encode via `URLComponents.percentEncodedHost`, or punycode via
`CFStringTransform`). **Verify the exact macOS 13 Foundation behaviour first** and add
table tests to `URLNormalizerTests` alongside.

### 🐛 P2 — every new window opens exactly on top of the last
`SiteWindowController.makeWindow` gives every window the same
`setFrameAutosaveName("SiteWindow")`. Separate (non-tabbed) windows all restore to one
identical frame and stack — no cascading, and the autosave key is fought over by every
window. **Fix:** only the first window of a launch uses the autosave name; subsequent
windows cascade (`window.cascadeTopLeft(from:)`). While there: a session saved with N
*separate* windows is restored as N tabs of one window (`restoreSession` passes
`asTabOf: first` for every window after the first) — restoring the separate-window
shape (or recording it) belongs in the same change.

### 🐛 P2 — preview downloads surface in the *builder's* Dock progress
`BoostPreviewController` sets `downloads.completion = .doNothing`, but
`DownloadCoordinator.begin` still `Progress.publish()`es every download — so clicking
a download link in the boost preview drives Wrapybara's own Dock progress indicator
and drops files in `~/Downloads` with no reveal. **Fix:** give `DownloadCoordinator`
a quiet mode (no publish, no Finder reveal, or cancel outright) and use it for the
preview. *Note: #15 touches `DownloadCoordinator`; sequence after it.*

### 🐛 P3 — session state saved only at quit
`SiteAppDelegate.saveSession()` runs in `applicationWillTerminate`. A crash (or
force-quit, or logout timeout) loses everything since launch, which quietly defeats
"reopen where I left off" for exactly the sessions that mattered. **Fix:** autosave
debounced off `onPageChanged` (e.g. 5 s after a change) — and do it together with the
SessionStore relocation below (⚡), which is what makes frequent saves cheap.

### 🐛 P3 — find is hard-wired case-insensitive
`FindBarController.find` sets `configuration.caseSensitive = false` always. Safari
offers an "Aa" match-case toggle in the field's context menu. **Fix:** small toggle
(⌥⌘F or a context-menu item on the field).

### 🐛 P3 — geolocation silently unsupported
WKWebView on macOS provides no geolocation permission UI to embedders; a site that
asks (weather, maps) gets nothing, and the generated `Info.plist` has no
`NSLocationUsageDescription` either. At minimum document the limitation (README/
PLAN); a real fix means implementing the permission prompt through CoreLocation and
adding the usage string to `InfoPlistBuilder`.

### 🐛 P3 — page zoom doesn't survive a relaunch (and ⌘0 doesn't mean "my default")
The live-reset half is fixed (#18); what remains is persistence: `⌘+`/`⌘−` zoom is
per-window, per-session, and `WrapBehavior.pageZoom`'s doc comment still claims
"⌘+/⌘− writes back to it" — nothing writes back. **Fix:** persist the live zoom per
wrap in the *site app's own* `UserDefaults` (runtime state, not configuration — the
two-writer rule is untouched), apply it on launch, and make ⌘0 reset to the configured
default rather than hard 100%. Fix or delete the comment either way.

### 🐛 P3 — the style-resurrection observer watches the wrong node
`BoostScripts.applyStylesheet` installs a `MutationObserver` on
`document.documentElement` (`childList`, no subtree) to re-install the boost
`<style>` if the page removes it — but the style element lives in `<head>`, one level
deeper. A SPA that clears or replaces *head's children* (hydration, meta managers)
removes the boost style without tripping the observer; only wholesale `<head>`/
`<body>` replacement is caught. **Fix:** also observe `document.head` once it exists
(re-arm after `DOMContentLoaded`). Touches `BoostScripts` — coordinate with
`RuntimeScriptTests`.

### 🐛 P3 — deprecated `activate(ignoringOtherApps:)` in the site runtime
`SiteAppDelegate.handleNotificationClick` calls
`NSApp.activate(ignoringOtherApps: true)`, deprecated in macOS 14 — a build warning
under Xcode 16. `UpdateChecker.runModal` already has the `#available(macOS 14)` dance;
copy it. Deliberately deferred from k3's pass: #6/#12/#13/#15 already queue on that
file — take it right behind them.

---

## Performance

### ⚡ P2 — `refreshStaleRuntimes` freezes the UI for the whole run
Building N stale wraps is N × (binary copy + icon render + `codesign`) all on the main
actor, with only the Build button's spinner as feedback. A dozen wraps ≈ several
seconds of beachball. **Fix:** at minimum a progress alert ("Rebuilding 3 of 12…");
properly, move the file/signing work off the main actor (the exporter's inputs are
values; the store hop back to main is one call). Mind `AGENTS.md`: signing stays
mandatory on every path.

### ⚡ P2 — `refreshFromPage` does full work on every KVO tick
`estimatedProgress` fires many times per load; each tick re-derives the title,
represented URL, toolbar label, `NSUserActivity` (`becomeCurrent()` per tick), Dock
badge, and now the reload⇄stop item (#22 added a same-state guard for its own slice).
**Fix:** diff-and-skip — only act when title/URL/flags actually changed — and/or
coalesce progress ticks. This also becomes the natural place to feed a thin
Safari-style progress bar (see ✨ below).

### ⚡ P2 — session blobs live in `UserDefaults` and can reach ~24 MB
`SessionStore` keeps up to 12 windows × 2 MB of `interactionState` in the app domain's
defaults — a synchronous XPC write into cfprefsd at every quit (and every future
autosave). The file's own comment admits "UserDefaults is the wrong place for
megabytes". **Fix:** write one file per wrap under the *site app's own*
`~/Library/Application Support/<bundleIdentifier>/` (not the shared `Wrapybara`
folder — the session must stay private to the app). Prerequisite for safe
autosave-on-change (🐛 above); do them together.

### ⚡ P3 — `SiteIconFetcher` buffers the whole response before its size cap
`fetchData` checks `data.count <= maximumResponseBytes` *after* `session.data(for:)`
returned — a `rel=icon` pointing at a 2 GB file is fully downloaded first. **Fix:**
`URLSession.bytes(for:)` with an early stop at the cap, or an `URLSessionDataDelegate`.

### ⚡ P3 — `BoostMatcher` cache is cleared on every `apply`
`SiteWebController.apply` calls `BoostMatcher.clearCache()` unconditionally, throwing
away compiled regexes for every open window on every configuration change. Only a
change to the boost *list* needs it; guard on the configuration actually having
changed (it's `Equatable`) before clearing. (#18 restructured `apply` — apply this on
top of its shape.)

### ⚡ P3 — every running wrap wakes on every wrap's publish
`ConfigurationWatcher` watches the shared `Runtime/` directory, so publishing wrap
A's config wakes wraps B…N, each of which re-reads and compares its own file (small
JSON, coalesced — cheap). At 12 running wraps × publish-all-on-launch it's a dozen
pointless wakeups a second. **Fix (later):** per-wrap subdirectories
(`Runtime/<uuid>/config.json`) so the directory watch is inherently scoped. Needs a
one-time migration read of the old flat path.

---

## Missing features

### ✨ P1 — drop/paste a URL on Wrapybara to create a wrap
`BuilderAppDelegate.application(open:)` treats every opened file as a boost import.
Dropping `https://example.com` (dragged from a browser address bar) onto the library
window should offer to wrap it. The plumbing exists (`URLNormalizer`, `store.makeWrap`,
`LibraryModel.createWrap`); it's an `.onDrop` on the sidebar. **Scope deliberately:**
*Dock-icon* drops of dragged URLs require declaring http(s) URL handling, which would
register Wrapybara as a browser candidate — the window/sidebar is the honest scope.
`.webloc` files arriving through `application(open:)` are worth parsing too.

### ✨ P2 — "Edit in Wrapybara" should land on *this* wrap
`SiteAppDelegate.openWrapybara()` launches the builder but can't say which wrap. The
site app knows its `WBWrapIdentifier`; Wrapybara could accept it (launch argument,
`NSUserActivity`, or a `wrapybara://wrap/<uuid>` URL scheme) and pre-select that row.
Kills the "which of my twelve wraps is this?" hunt.

### ✨ P2 — per-wrap storage clearing
Phase 3 in `PLAN.md`. The natural home is the site app's Settings window (the app owns
its session): "Clear cookies and website data" + "Clear cache" via
`WKWebsiteDataStore.removeData`. Keep the two-writer rule: these are *runtime*
operations, not configuration edits. (#13 rebuilt that window's refresh path — build
on its shape.)

### ✨ P2 — content blocker per wrap (`WKContentRuleList`)
Also Phase 3, and the most-requested wrapper feature that doesn't exist yet. A
built-in "hide cookie banners / block trackers" rule list compiles once and injects
per wrap in `SiteWebViewFactory`; toggle in Behaviour. Keep the rule list as JSON
*in Swift string literals* per the `AGENTS.md` rule about resources (or revisit that
rule deliberately — it exists because `AppBundleWriter` copies only the executable).
Note the presets gallery (#23) now ships the CSS-only version; the rule list is the
engine-level upgrade.

### ✨ P2 — undo in the boost editor
Phase 2. Every knob writes straight through to the store; there is no ⌘Z anywhere
(the Edit menu's Undo reaches only text fields). An `NSUndoManager` on
`LibraryModel.updateBoost` covers knobs and zaps uniformly.

### ✨ P2 — Save page as PDF / Copy Page Image
`WKWebView.createPDF` / `takeSnapshot` are public API; File-menu "Export as PDF…" and
"Copy Image of Page" are small, genuinely useful, and very Mac.

### ✨ P2 — a match tester that accepts any URL in the Scope pane
The Scope pane's "Does it match the home page?" line is the boost editor's best
teaching moment, and it stops one step short: you can't ask about the page you're
actually scoping (a settings subpage, a docs path). A small "test a URL" field under
it running `BoostMatcher.matches` live closes the loop — pure matcher, one `@State`
string. (From k3 K19.)

### ✨ P2 — a running wrap should learn that a newer Wrapybara exists
A wrap checks for its *configuration* changing but never learns that the Wrapybara
that built it shipped a newer runtime — the stale-runtime badge only exists in the
builder's library, and users who rarely open Wrapybara never see it. One line in the
site app's Settings window ("Built by Wrapybara 1.0 — 1.2 is available") needs
nothing but the existing `UpdateChecker` pointed at the same repo. (k3 K28.)

### ✨ P3 — ⌘L with recent addresses
The Go-to-Address sheet has no history. A short recents list (even 5, from the
session store's back-forward entries) would make it far more usable.

### ✨ P3 — PWA-aware wrapping
The fetcher already reads the web app manifest for icons/names; it could also use
`start_url` as the home URL, `display: standalone` to default the chrome to
"title bar only", and `theme_color` for the default window background. Wrapping a
real PWA would then need one click instead of four corrections.

### ✨ P3 — duplicate a wrap
Context-menu "Duplicate" (new id, new bundle identifier, " 2" name). The obvious
work/personal second-account path, currently a manual re-entry of everything.
`WrapStore.makeWrap` shows the uniquifying pattern to follow.

### ✨ P3 — library drag-to-reorder
The sidebar has no ordering. `WrapStore` has a comment noting where the reorder
belongs when it's added (`LibraryModel`, which already imports SwiftUI). An
alphabetical-sort toggle would do too.

### ✨ P3 — export/import a whole wrap
`.wrapyapp` file = configuration + icon PNG, importable on another Mac. The pieces
exist (boost export/import already does the same dance); `AppBundleWriter`-style
staging applies if it becomes a directory.

### ✨ P3 — thin loading progress bar (the deluxe half of #22)
#22 shipped the reload⇄stop swap. The Safari-style thin progress bar under the
toolbar is the deluxe version, and it wants the `estimatedProgress` diff-and-coalesce
(⚡P2 above) to land first so it doesn't tick-draw per KVO event.

### ✨ P3 — small editor affordances (three tiny ones)
Inline enable/disable checkboxes for wrap-local boosts (the shared section has them;
local rows still require the editor). An icon size strip (16/32/64/128 pt) in the
Site tab so bad icons fail before the Dock. A "Copy Generated CSS" button in the Code
pane (`BoostCSSGenerator` is pure). Each is minutes of work. (k3 K20–K22.)

### ✨ P3 — "Open App" / "Reveal in Finder" on the build-success alert
The alert currently shows the destination path and OK; when `launchAfterBuild` /
`revealAfterBuild` are off it's a dead end. Three lines in `LibraryModel.build`.
(k3 K23.)

---

## Visual issues & layout

### 🎨 P2 — transparent-title-bar mode has no top inset handling
With `chrome = .none` (`fullSizeContentView` + transparent title bar), the find bar
slides in at the very top of the window — directly under the traffic lights — and the
page's top content is obscured by them. **Fix:** pin the find bar below the safe
area, and offer (or default to) a modest `additionalSafeAreaInsets` for the web view
in this mode.

### 🎨 P2 — icon-only buttons without accessibility labels
The preview status bar, the boosts footer and the library footer use bare
`Image(systemName:)` buttons with `.help()` tooltips but no `accessibilityLabel`
(the preset menu in #23 got one; the rest haven't). VoiceOver reads them as
"button". One-line fixes throughout; grep `buttonStyle(.borderless)` for the set.

### 🎨 P3 — segmented Picker as the wrap editor's tab control
macOS convention for this shape is a toolbar-based tab. Consider an `NSToolbar`-backed
titlebar row for Site/Behaviour/Boosts — the site app already demonstrates the
pattern (`SiteWindowController.installToolbar`). While there: the boost editor's own
toolbar (toggle + name + 4-segment picker + preview button) crowds at its 340 pt
minimum — the name field collapses to a sliver; an icon-picker variant or a higher
min-width would fix it. (k3 K25.)

### 🎨 P3 — the address "field" in the site toolbar is a plain label
Good (no omnibox creep), but there's no affordance that ⌘L/click works and no lock
icon for https. A subtle "⌘L" hint on hover would teach the shortcut for free.

### 🎨 P3 — zap picker overlay color is fixed brown
`#8B5A2B` (this project's own brand tint) on brown-tinted sites can be low contrast.
Compute the highlight from the wrap's `tintHex` complement, or offer blue/red.

### 🎨 P3 — the boost preview looks dead while loading
The preview status bar has reload/home/URL/pick but no activity indication — loading a
heavy site looks frozen. `BoostPreviewController` already receives
`siteWebControllerDidChangeState`; an `@Published isLoading` + a small `ProgressView`
in the status bar is the whole fix. Fold the preview-downloads quiet mode (🐛P2 above)
into the same pass. (k3 K26.)

---

## UX, convenience, delight

### 💡 P2 — the boost editor's code drafts go stale on external change
The CSS/JS `@State` drafts are snapshotted in `onAppear` only; if the same boost
changes elsewhere while the Code pane is open (the Zap picker appends a selector),
the drafts can overwrite on the next keystroke. With the publish-debounce landed
(PR #3), typing stays live everywhere it matters; reconcile drafts on external change
(e.g. `.onChange(of: boost.updatedAt)`) — carefully, so reconciling never fights the
user's cursor mid-edit.

### 💡 P2 — keyboard shortcuts for boosts
Per-wrap global hotkeys are Phase 4, but *in-app* shortcuts ("⌘1 toggles my Dark
boost") need no system integration: a Boosts submenu with checkable items, wired
through the existing live-config reload, would make toggling a theme instant.

### 💡 P2 — "What did this boost change?" diff view
Phase 2 item and the best answer to "boosts are magic". A simple two-column
generated-CSS diff (before/after knob values) is enough; no DOM diff needed.
`BoostCSSGenerator` being pure makes this table-testable.

### 💡 P2 — multi-select zap
Shift-click several elements in the picker to zap them all (collect selectors,
commit on Enter). Today each pick is a separate round-trip through the editor.
The picker's message protocol already carries one selector — extend the payload.

### 💡 P3 — wrap "health check" in the library
A small diagnostic row: reachable? manifest found? icon quality (≥128 px)? SSO hosts
configured? Catches "why does my app look bad" at a glance. The fetcher's
`discover(at:)` already returns most of the inputs.

### 💡 P3 — quirky: Dock badge for *Wrapybara itself* showing stale-runtime count
The builder already computes `staleWrapCount` for the footer — mirror it on the
builder's Dock icon. A wrapper that keeps its own apps fresh is the whole brand.

### 💡 P3 — quirky: capybara easter egg
The name deserves one: capybara art in the About panel, a tasteful sound on first
successful build, or the empty-library illustration. One smile, no features harmed.

### 💡 P3 — template gallery ("one-click wraps")
A New Wrap sheet tab with a handful of curated sites (Gmail, Notion, Linear, Figma,
YouTube Music) pre-tuned (UA, extra in-app hosts, chrome). Low effort — they're just
`Wrap` values — and it turns the empty state into a demo. Natural follow-on to the
preset gallery (#23).

### 💡 P3 — per-wrap icon drag-out
Let the library row's icon be draggable (NSPasteboard file promise or just the PNG) —
users assemble their own docs/screenshots.

### 💡 P3 — window-title zoom indicator
When zoom ≠ the configured default, a Safari-style transient "125%" in the toolbar
teaches that zoom exists — pairs with zoom persistence (🐛P3 above), which makes the
indicator honest rather than noisy. (k3 K29.)

---

## Code health

### P2 — no "takes effect on next page load" hint for UA/zoom changes
(#18 now *reloads* on a live UA change, so the UA half is resolved; zoom-from-the-
editor propagates live by design.) Remaining: the inspector toggle's "next launch"
caption is the pattern — audit the Behaviour tab for anything else that needs one and
say it next to the control.

### P2 — `CodeEditor.disableSmartSubstitutions` writes process-wide UserDefaults
It permanently writes four defaults keys into Wrapybara's domain (they persist across
relaunches and affect every text field in the app, including prose fields like boost
notes). Works, but the documented blast radius is understated. Prefer setting the
keys at launch only if a code editor has ever been used, or reverting when the editor
closes.

### P3 — `WrapStore` has no migration hook
`formatVersion` exists on both documents but nothing reads it to branch. Fine today
(version 1, additive-only decoding); add the switch before version 2 needs one —
`WrapConfiguration.isReadable` already refuses future formats, which is half the job.

### P3 — three copies of `isRunningTests` (and now two activation dances)
`SiteAppDelegate`, `BuilderAppDelegate` and `UpdateChecker` each define the same
helper, and once the `activate(ignoringOtherApps:)` deprecation fix (🐛P3 above) lands
the `#available(macOS 14)` activation dance exists in two places. One tiny
`Common/` home (`LaunchMode.isRunningTests` + `NSApplication.activateToFront()`)
would pay rent.

### P3 — remaining magic strings
Handler names are centralized (`BoostScripts.Handler`) — good — but
`com.wrapybara.Wrapybara` in `SiteAppDelegate.openWrapybara` and the toolbar/tabbing
identifiers are literals that belong next to `InfoPlistBuilder` /
`BundleIdentifierGenerator`.

### P3 — small parser/import nits
`SiteMarkupParser.decodingEntities` handles named entities but not numeric ones
(`&#x27;`, `&#38;`) — rare in `<head>` attributes, but `&#39;` is already there, so the
table is halfway to pretending. `importBoosts` does `Data(contentsOf:)` with no size
cap (the icon fetcher has one; a 1 MB ceiling matches its discipline).
`WrapEditorView`'s header comment promises drafts commit "on focus loss"; the code
commits on submit and on *disappear*. `confirmsQuitWithOpenTabs` counts *windows*,
not tabs — with native tabs, two tabs in one window get no confirm.

---

## Guard rails (things a refactor must not flatten)

- The pure-and-tested decidable core: `BoostMatcher`, `BoostCSSGenerator`,
  `NavigationPolicy`, `BadgeFromTitle`, `AppNameSanitizer`,
  `BundleIdentifierGenerator`, `InfoPlistBuilder`, `SiteMarkupParser`,
  `URLNormalizer`, `IconCandidate.ranked` — plus the new `SiteErrorPage`.
- The byte-copy single binary with seed + live config, newest-`generatedAt`-wins.
- Directory (not file) watching; atomic writes; decode-with-defaults everywhere.
- Honest UI about heuristic restyling (the colour-reach trade-off copy; the presets
  carry their own trade-off notes).
- The notification trust model for imported scripts (untrusted until read).
- The find bar via WebKit's own `find`; the Smart-Invert-style media counter-filter.
- The selector ladder that rejects framework-generated identifiers.
- The error page's guarantees: escaped interpolation, web-only retry targets,
  boosts stripped so the recovery screen stays legible (see #24's thread for the
  reasoning — the trade-offs were litigated in review).
