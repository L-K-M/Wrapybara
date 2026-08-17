# ANALYSIS.md — Wrapybara backlog

Shovel-ready findings from a full review of the codebase (~10k lines of Swift, every
module), maintained as the pick-up list for future work. Each entry says what's wrong
(or missing), why it matters, where it lives, and how to fix it. When you finish an
entry, delete it — that's the deal.

Priorities: **P1** should fix soon · **P2** worth doing · **P3** nice / later.
Types: 🐛 bug · ⚡ performance · 🎨 visual/layout · ✨ feature · 💡 idea.

Related documents: `PLAN.md` (design), `AGENTS.md` (constraints — read before touching
export/signing/boost trust), `glm.md` (the original review this list came from).

---

## In flight — open PRs, reviewed and waiting (do not duplicate)

Twelve small, high-confidence fixes from the same review are already implemented,
CI-green, and reviewed (GLM feedback addressed) in open PRs against `main`:

| PR | Branch | One-liner |
| --- | --- | --- |
| [#2](https://github.com/L-K-M/Wrapybara/pull/2) | `perf/library-icon-cache` | Cache decoded wrap icons (`NSCache`, byte-cost budget) instead of disk-read + decode per sidebar render. |
| [#3](https://github.com/L-K-M/Wrapybara/pulls/3) | `perf/debounce-runtime-publish` | Debounce `Runtime/<uuid>.json` publication with the library save; retry failed publishes. |
| [#4](https://github.com/L-K-M/Wrapybara/pull/4) | `fix/signing-timestamp` | `--timestamp=none` only for ad-hoc; explicit `--timestamp` for Developer ID. |
| [#5](https://github.com/L-K-M/Wrapybara/pull/5) | `fix/restore-boosts` | Install the restored page's boosts after session restore (was home page's). |
| [#6](https://github.com/L-K-M/Wrapybara/pull/6) | `fix/badge-all-windows` | Dock badge = max unread count across all windows/tabs. |
| [#7](https://github.com/L-K-M/Wrapybara/pull/7) | `fix/share-picker-anchor` | Anchor the share menu to the invoking control (was window's bottom-left corner). |
| [#8](https://github.com/L-K-M/Wrapybara/pull/8) | `fix/rename-collision` | Uniquify a wrap's name on rename so two wraps can't share one `.app`. |
| [#9](https://github.com/L-K-M/Wrapybara/pull/9) | `fix/zap-menu-site-app` | Remove the Zap menu items from generated apps (they silently discarded picks). |
| [#10](https://github.com/L-K-M/Wrapybara/pull/10) | `fix/remove-dead-cookie-flag` | Delete the never-wired `blocksThirdPartyCookies` knob. |
| [#11](https://github.com/L-K-M/Wrapybara/pull/11) | `perf/preview-apply-skip` | Skip no-op boost-preview applies on unrelated SwiftUI renders. |
| [#12](https://github.com/L-K-M/Wrapybara/pull/12) | `feat/site-dock-menu` | Dock menu for generated apps: New Window / New Tab / Go to Home Page. |
| [#13](https://github.com/L-K-M/Wrapybara/pull/13) | `fix/stale-settings-window` | Refresh the site app's Settings window when its configuration changes. |

---

## Bugs

### 🐛 P2 — notification clicks route to whichever window is front
`SiteAppDelegate.handleNotificationClick(pageID:)` evaluates
`notificationClicked(id)` in the **front** window's web view. A notification posted by
a background window's page activates the wrong window's callback (or nothing, if that
window was closed). **Fix:** carry the source window through `NotificationBridge`
(id → weak `SiteWindowController` map, populated in the `onNotification` closure the
app delegate already installs per controller) and route the click there, falling back
to the front window.

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
windows cascade (`window.cascadeTopLeft(from:)`).

### 🐛 P2 — preview downloads surface in the *builder's* Dock progress
`BoostPreviewController` sets `downloads.completion = .doNothing`, but
`DownloadCoordinator.begin` still `Progress.publish()`es every download — so clicking
a download link in the boost preview drives Wrapybara's own Dock progress indicator
and drops files in `~/Downloads` with no reveal. **Fix:** give `DownloadCoordinator`
a quiet mode (no publish, no Finder reveal, or cancel outright) and use it for the
preview.

### 🐛 P3 — session state saved only at quit
`SiteAppDelegate.saveSession()` runs in `applicationWillTerminate`. A crash (or
force-quit, or logout timeout) loses everything since launch, which quietly defeats
"reopen where I left off" for exactly the sessions that mattered. **Fix:** autosave
debounced off `onPageChanged` (e.g. 5 s after a change). Note `SessionStore.save` is
already pure-ish and cheap; mind `maximumStateBytes`.

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
represented URL, toolbar label, `NSUserActivity` (`becomeCurrent()` per tick) and Dock
badge. **Fix:** diff-and-skip — only act when title/URL/flags actually changed —
and/or coalesce progress ticks. (This also becomes the natural place to feed the
loading-progress UI below.)

### ⚡ P3 — `SiteIconFetcher` buffers the whole response before its size cap
`fetchData` checks `data.count <= maximumResponseBytes` *after* `session.data(for:)`
returned — a `rel=icon` pointing at a 2 GB file is fully downloaded first. **Fix:**
`URLSession.bytes(for:)` with an early stop at the cap, or an `URLSessionDataDelegate`.

### ⚡ P3 — `BoostMatcher` cache is cleared on every `apply`
`SiteWebController.apply` calls `BoostMatcher.clearCache()` unconditionally, throwing
away compiled regexes for every open window on every configuration change. Only a
change to the boost *list* needs it; guard on the configuration actually having
changed (it's `Equatable`) before clearing.

---

## Missing features

### ✨ P1 — a real error page for failed navigations
A wrap launched offline shows a blank white window (`SiteWebController.report(_:)`
only NSLogs). Safari's "can't open the page … because the server cannot be found"
with a **Try Again** button is the expected behaviour and a small `loadHTMLString`
away. This is the single most user-visible gap in the runtime. Suggested shape: a
`SiteErrorPage` helper that renders styled HTML (keep the wrap's name/colours, show
the failed URL and the error's localized description, a retry button that re-issues
the failed request via a script-message or a `window.location` dance through
`URLNormalizer`).

### ✨ P1 — loading progress is observed but never shown
`estimatedProgress` is KVO'd and drives nothing. The reload toolbar button should
spin/become Stop while loading (the menu's Stop Loading validates correctly; the
toolbar has no state at all). A thin progress bar under the toolbar (Safari-like) is
the deluxe version; swapping reload⇄stop is the minimum.

### ✨ P1 — drop/paste a URL on Wrapybara to create a wrap
`BuilderAppDelegate.application(open:)` treats every opened file as a boost import.
Dropping `https://example.com` (dragged from a browser address bar) onto the Dock icon
or the library window should offer to wrap it. The plumbing exists
(`URLNormalizer`, `store.makeWrap`, `LibraryModel.createWrap`); it's a two-branch `if`
in the open-urls handler plus a drop delegate on the sidebar.

### ✨ P2 — "Edit in Wrapybara" should land on *this* wrap
`SiteAppDelegate.openWrapybara()` launches the builder but can't say which wrap. The
site app knows its `WBWrapIdentifier`; Wrapybara could accept it (launch argument,
`NSUserActivity`, or a `wrapybara://wrap/<uuid>` URL scheme) and pre-select that row.
Kills the "which of my twelve wraps is this?" hunt.

### ✨ P2 — per-wrap storage clearing
Phase 3 in `PLAN.md`. The natural home is the site app's Settings window (the app owns
its session): "Clear cookies and website data" + "Clear cache" via
`WKWebsiteDataStore.removeData`. Keep the two-writer rule: these are *runtime*
operations, not configuration edits.

### ✨ P2 — content blocker per wrap (`WKContentRuleList`)
Also Phase 3, and the most-requested wrapper feature that doesn't exist yet. A
built-in "hide cookie banners / block trackers" rule list compiles once and injects
per wrap in `SiteWebViewFactory`; toggle in Behaviour. Keep the rule list as a JSON
resource *in Swift string literals* per the `AGENTS.md` rule about resources (or
revisit that rule deliberately — it exists because `AppBundleWriter` copies only the
executable).

### ✨ P2 — boost presets gallery
Phase 2. Ship a handful of well-made shared boosts (Dark, Readable, Kill Sticky
Headers, No Cookie Banners, Monospace Everything) as built-ins on the shared shelf.
Cheap (they're `Boost` values), high perceived value, and they teach the model better
than prose.

### ✨ P2 — undo in the boost editor
Phase 2. Every knob writes straight through to the store; there is no ⌘Z anywhere
(the Edit menu's Undo reaches only text fields). An `NSUndoManager` on
`LibraryModel.updateBoost` covers knobs and zaps uniformly.

### ✨ P2 — Save page as PDF / Copy Page Image
`WKWebView.createPDF` / `takeSnapshot` are public API; File-menu "Export as PDF…" and
"Copy Image of Page" are small, genuinely useful, and very Mac.

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

---

## Visual issues & layout

### 🎨 P2 — transparent-title-bar mode has no top inset handling
With `chrome = .none` (`fullSizeContentView` + transparent title bar), the find bar
slides in at the very top of the window — directly under the traffic lights — and the
page's top content is obscured by them. **Fix:** pin the find bar below the safe
area, and offer (or default to) a modest `additionalSafeAreaInsets` for the web view
in this mode.

### 🎨 P2 — icon-only buttons without accessibility labels
The preview status bar and the boosts footer use bare `Image(systemName:)` buttons
with `.help()` tooltips but no `accessibilityLabel`. VoiceOver reads them as
"button". One-line fixes throughout; grep `buttonStyle(.borderless)` for the set.

### 🎨 P3 — segmented Picker as the wrap editor's tab control
macOS convention for this shape is a toolbar-based tab. Consider an `NSToolbar`-backed
titlebar row for Site/Behaviour/Boosts — the site app already demonstrates the
pattern (`SiteWindowController.installToolbar`).

### 🎨 P3 — the address "field" in the site toolbar is a plain label
Good (no omnibox creep), but there's no affordance that ⌘L/click works and no lock
icon for https. A subtle "⌘L" hint on hover would teach the shortcut for free.

### 🎨 P3 — zap picker overlay color is fixed brown
`#8B5A2B` (this project's own brand tint) on brown-tinted sites can be low contrast.
Compute the highlight from the wrap's `tintHex` complement, or offer blue/red.

### 🎨 P3 — empty shared-boosts section says "None yet" twice
Both sections of the boosts list show "None yet" placeholders when empty; one
well-set empty state ("Shared boosts are switched on per app — import a
`.wrapyboost` file or promote one of yours") would teach the feature.

---

## UX, convenience, delight

### 💡 P2 — the boost editor's code drafts go stale on external change
The CSS/JS `@State` drafts are snapshotted in `onAppear` only; if the same boost
changes elsewhere while the Code pane is open (the Zap picker appends a selector),
the drafts can overwrite on the next keystroke. With the publish-debounce landed
(PR #3), typing stays live everywhere it matters; reconcile drafts on external change
(e.g. `.onChange(of: boost.updatedAt)`) or re-derive through a dedicated binding.

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
`Wrap` values — and it turns the empty state into a demo.

### 💡 P3 — per-wrap icon drag-out
Let the library row's icon be draggable (NSPasteboard file promise or just the PNG) —
users assemble their own docs/screenshots.

---

## Code health

### P2 — no "takes effect on next page load" hint for UA/zoom changes
`SiteWebController.apply` sets `pageZoom`/`customUserAgent` live, but the UA only
affects the *next* navigation; sites that fingerprint at load won't re-evaluate. A
one-line caption in the Behaviour tab (like the inspector toggle's) would prevent
confusion.

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

### P3 — three copies of `isRunningTests`
`SiteAppDelegate`, `BuilderAppDelegate` and `UpdateChecker` each define the same
helper. One shared spot (`LaunchMode.isRunningTests`, or a tiny
`Common/TestSupport.swift`) would do.

### P3 — remaining magic strings
Handler names are centralized (`BoostScripts.Handler`) — good — but
`com.wrapybara.Wrapybara` in `SiteAppDelegate.openWrapybara` and the toolbar/tabbing
identifiers are literals that belong next to `InfoPlistBuilder` /
`BundleIdentifierGenerator`.

---

## Guard rails (things a refactor must not flatten)

- The pure-and-tested decidable core: `BoostMatcher`, `BoostCSSGenerator`,
  `NavigationPolicy`, `BadgeFromTitle`, `AppNameSanitizer`,
  `BundleIdentifierGenerator`, `InfoPlistBuilder`, `SiteMarkupParser`,
  `URLNormalizer`, `IconCandidate.ranked`.
- The byte-copy single binary with seed + live config, newest-`generatedAt`-wins.
- Directory (not file) watching; atomic writes; decode-with-defaults everywhere.
- Honest UI about heuristic restyling (the colour-reach trade-off copy).
- The notification trust model for imported scripts (untrusted until read).
- The find bar via WebKit's own `find`; the Smart-Invert-style media counter-filter.
- The selector ladder that rejects framework-generated identifiers.
