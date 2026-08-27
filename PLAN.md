# Wrapybara — design & plan

Wrapybara turns a website into a **real Mac app**. Not a Chromium window with the
tab bar hidden: an `.app` bundle with its own icon, its own bundle identifier, its
own login session, a full menu bar, native tabs, a native find bar, real downloads,
Handoff, and a Dock badge. And **Boosts** — per-site colour, type and layout
customisation, hidden elements, and your own CSS and JavaScript, in the spirit of
Arc's Boosts and Zen's Mods.

---

## 1. Why this exists

There are already several ways to wrap a site on a Mac.

| | Engine | What you get |
| --- | --- | --- |
| **WebCatalog** | Chromium (Electron) | A catalogue of pre-made wrappers. Big; the apps are Electron. |
| **Unite** | WebKit | Small apps, decent integration. Closed, paid, no site customisation. |
| **Coherence X** | Chromium | Chrome profiles per app. Big apps; the result doesn't feel Mac-native. |
| **Safari → Add to Dock** | WebKit | Free and native, but almost no control: no per-app UA, no custom icon beyond the site's, no CSS/JS, no link-routing policy. |

The complaint that started this: *the apps Coherence creates aren't real Mac apps.*
That is a fair description of the whole category. The tells are specific and
fixable:

- **The icon.** A site's `apple-touch-icon` is a full-bleed square drawn for an iOS
  home screen. Dropped into a Mac bundle it sits in the Dock as a hard square among
  rounded plates, at the wrong visual weight. And with no `@2x` slots it looks soft.
- **The menu bar.** Either absent or a stub. No ⌘L, no ⌘F that actually finds, no
  Print, no Share, no Services — often not even a working ⌘C in a text field.
- **Tabs.** A wrapper usually has one window and no `NSWindow` tabbing, so ⌘T does
  nothing.
- **Links.** Either everything opens in the app (so it silently becomes a bad
  browser) or everything leaves (so a login redirect dumps you into Safari
  mid-handshake).
- **Downloads.** Dropped, or navigated to and rendered as binary garbage.
- **State.** Reopens at the home page rather than where you were.
- **Weight.** A few hundred megabytes of Chromium per app.

Wrapybara's whole thesis is that these are the product, not the polish.

### What Boosts add

Arc's Boosts let you recolour a site, change its fonts, **Zap** (hide) elements you
don't want, and write CSS and JavaScript against it. Zen does something similar with
a colour filter implemented inside the engine's style resolution. Both are
per-site customisation, and both are the reason people put up with a whole browser.

If you're already building a per-site app, per-site customisation belongs in it.
A wrap of your ticket tracker is exactly the place to hide the marketing banner
forever.

---

## 2. Engine choice

This deserves a straight answer because it constrains everything else.

### WebKit (`WKWebView`) — chosen

- **It's already on the Mac.** No engine to ship, so a wrap is a few megabytes, not
  a few hundred. Twelve wraps cost roughly twelve copies of one small binary.
- **It's the native one.** Rubber-band scrolling, `NSTextFinder`-style find,
  Look Up, Services, the share sheet, system autofill and Keychain passwords,
  Apple Pay, per-app cookie isolation by bundle identifier, the system's power
  management, and a title bar that behaves. None of this has to be re-implemented,
  and none of it can be re-implemented *quite* right on top of another engine.
- **Security patching is the OS's problem.** A Chromium-bundling wrapper is
  responsible for shipping every CVE fix to every app it ever generated. That is a
  serious ongoing obligation and this project would not meet it.
- **The costs are real and worth naming.** No extensions. No DevTools protocol.
  Web push is unavailable to embedders (hence the notification shim). No per-app
  engine version pinning, so a Safari regression is a wrap regression. Some sites
  sniff for Chrome and degrade.

### Chromium (CEF / Electron) — rejected

Buys extensions, DevTools and Chrome-only site compatibility. Costs 150–200 MB per
app, a native-feel deficit in exactly the places this project cares about, and the
patch-shipping obligation above. Coherence made this trade and the result is the
thing the user didn't like.

### Gecko — not currently possible

Mozilla has had no supported embedding API since the XULRunner/`GeckoEmbed` era was
retired. GeckoView is Android-only. Embedding Gecko on macOS today means forking
Firefox, which is not a foundation for a small utility.

### Servo — genuinely interesting, still not ready for this app

Re-checked August 2026: Servo is up to **0.5.0 on crates.io** (0.1.0 landed in
April 2026), developed on 64-bit macOS among other platforms, with the embedder
surface split into a `servo` crate and `servo-embedder-traits`. The trajectory is
real and encouraging. The embedding *shape*, though, is the same as it was, and
it collides with this project's design at three specific points:

- **It isn't an `NSView`.** Servo renders through WebRender and expects the
  embedder to provide the windowing and event loop — servoshell does it with
  `winit`. Hosting that inside Wrapybara's `NSWindow`/toolbar/native-tabs model
  means either a child window (which breaks the title bar, tabs and find bar that
  make a wrap feel native) or compositing an offscreen buffer into a `CALayer`
  and re-plumbing input, IME, drag-and-drop and gestures by hand — re-implementing
  exactly what WebKit already gives, and never quite right.
- **Per-app isolation is ours to build.** A wrap's cookies and storage are keyed
  by its bundle identifier today, for free. Servo's embedding API has no
  equivalent of that per-app data-store story, so each wrap's session would be a
  storage path we manage ourselves.
- **It breaks the size and signing model.** The runtime inside every generated
  app is a byte copy of Wrapybara's own few-megabytes binary. A Servo wrap would
  need the engine (on the order of a hundred megabytes, plus a Rust build in CI
  and this project's first dependency) copied into the bundle, stripped of
  quarantine and signed alongside the executable — a different bundle layout per
  engine, not a per-wrap toggle in today's writer.

Add the standing costs — web-platform coverage still short of the rich sites
people wrap (and media only via an optional GStreamer dependency), and the
security-patch obligation moving from the OS to us — and the honest answer to a
per-wrap engine picker remains "not yet".

**The plan is to keep the door open, not to walk through it now.** The runtime's
web-view usage is deliberately funnelled through `SiteWebViewFactory`,
`SiteWebController` and `BoostInjector`; a second backend means implementing that
surface, not rewriting the app. Boosts are already expressed as CSS text and
selectors rather than as WebKit calls, so they port unchanged. The first real
step, when Servo's platform coverage makes it honest, is a standalone spike —
libservo rendering one URL into a `CALayer` in a throwaway app — *before* any
surgery here, and Phase 6 below is the per-wrap engine setting that would
surface it.

---

## 3. Shape of the thing

One Xcode target, one binary, two lives.

```
Wrapybara.app                     the builder: library, editors, exporter
└── Contents/MacOS/Wrapybara      ← this exact binary is copied…

Claude.app                        …into every app it builds
├── Contents/MacOS/Claude         a byte copy of the Wrapybara binary
├── Contents/Info.plist           hand-written: identity, icon, WBWrapIdentifier
└── Contents/Resources/
    ├── AppIcon.icns              composed artwork, all ten slots
    └── wrap.json                 the baked-in seed configuration
```

`LaunchMode.detect()` reads the running bundle's `Info.plist`. A `WBWrapIdentifier`
key means "you are a site app"; its absence means "you are the builder".

### Why one binary rather than an embedded helper app

The alternative is for Wrapybara to embed a separate `WrapybaraSite.app` and copy it
out. One binary wins on the things that matter:

- **A generated app is standalone.** It holds no path or reference back to
  Wrapybara, so deleting or moving the builder cannot break the twelve apps it
  built.
- **Nothing nested to sign.** No nested-bundle placement question, no `--deep`
  re-signing of a helper inside a helper.
- **One target, one build, one place for a bug to live.**

The cost is that every wrap carries the builder's code as dead weight — a few
megabytes, against a Chromium wrapper's few hundred. Accepted.

### Signing is mandatory, and needs the Command Line Tools

A bundle's code signature seals its `Info.plist`. The exporter writes a brand-new
one, so the copied binary's inherited signature no longer validates — and on Apple
Silicon the kernel refuses to execute an arm64 binary whose signature doesn't
validate. So every generated app is re-signed, ad-hoc by default
(`codesign --force --deep --sign -`), or with a Developer ID if the user has one.

`/usr/bin/codesign` is a Command Line Tools shim. When it isn't there, that is a
first-class, explainable error with the fix in it (`xcode-select --install`), not a
mysterious app that dies on launch.

### Where configuration lives, and why in two places

| Copy | Written by | Read when |
| --- | --- | --- |
| `<App>.app/Contents/Resources/wrap.json` | the exporter, at build time | always available; the reason a wrap survives Wrapybara being deleted |
| `~/Library/Application Support/Wrapybara/Runtime/<uuid>.json` | Wrapybara, on every edit | the live copy a *running* app picks up |

`WrapConfiguration.newer(bundled:stored:)` takes whichever has the later
`generatedAt`. That gets both directions right: editing a boost beats the baked-in
seed, and rebuilding the app beats a stale store entry. A generated app watches the
directory (not the file — atomic writes replace the inode) and re-applies without a
relaunch. Drag a slider in the boost editor; the app in front of you restyles.

---

## 4. Boosts

A boost is a value type with four parts and a scope.

| Part | What it is |
| --- | --- |
| `theme` | Knobs: background/text/link/accent colour, colour *reach*, font stacks, text size and line height, case, readable width, brightness/contrast/saturation/hue/invert/greyscale, corner radius, hide images. |
| `zapSelectors` | CSS selectors to hide, added one at a time by the element picker. |
| `css` | Your own CSS. Emitted last, so it always wins. |
| `javaScript` | Your own script, at `documentStart` or `documentEnd`, gated on a trust flag. |
| `match` | Everywhere / domain (± subdomains) / URL prefix / glob / regex. |

`BoostCSSGenerator` turns a theme into CSS, and it is pure, deterministic, and
tested against its output rather than against a screenshot. Three properties are
load-bearing:

1. **An untouched theme generates nothing.** Every knob's identity value is its
   neutral one, so "boost enabled but empty" costs no `<style>` element.
2. **Values that don't parse are dropped, not escaped.** A colour that isn't a
   colour emits no declaration. A zap selector containing a brace is discarded
   rather than mangled into something that no longer selects what the user picked.
3. **Order is fixed.** Filters, then colours (blanket rules before the link rule
   that has to survive them), then type, then surfaces, then zaps, then user CSS.

### The honest limitation

Zen can filter colours inside the engine's style resolution. A `WKWebView` embedder
cannot, so this is a stylesheet with `!important` on it, and restyling an arbitrary
site that way is heuristic. Rather than pretend otherwise, the reach of the
aggressive option is a visible setting (`ColorReach.everything` clears every
element's `background-color` so the root colour shows through) with its trade-off
written next to it in the UI.

### The element picker

Injected into the page: hover highlights, click selects, **↑ widens the selection to
the container** and ↓ narrows it back, Esc cancels. Widening is what Arc calls "zap
all related elements" — one element is rarely what you meant; you meant its
container.

Selector generation walks a ladder — an id that looks authored, then classes that
look authored, then a positional path — and stops as soon as the selector is unique.
Framework-generated identifiers (`css-1x2y3z`, hash-like tokens, `ember123`) are
rejected, because a selector built from one stops matching on the next deploy.

### JavaScript trust

A boost is a shareable file whose script would run in the page's origin, inside
whatever session that app is signed into. So:

- Boosts you write are trusted on save.
- Boosts that arrive by **import** are not. Their script is inert until you read it
  and say so, and they arrive switched off.
- **Export clears the trust flag**, so a boost you hand to someone else arrives
  inert on their side too.
- CSS needs no such gate: it can restyle a page but cannot read it.

---

## 5. What makes a generated app feel native

Not one feature — the absence of twenty small failures.

- **Icon.** Site artwork is *composed* onto a macOS-proportioned rounded plate
  (824/1024, Apple's grid) with a gradient and a hairline, at all ten slots
  including every `@2x`. Or used as-is, if the user prefers. Or a monogram on a
  tinted plate derived from the site's own `theme-color`. The plate is the user's
  to restyle: any colour, or one of the classic 8×8 Mac desktop tiles drawn flat
  in two tones of it (`PlatePattern`). The raw artwork is kept on disk next to
  the composed icon, so restyling never means re-fetching.
- **Menu bar.** App / File / Edit / View / History / Window / Help, every item
  wired: ⌘L, ⌘F with ⌘G and ⇧⌘G, ⌘R and ⇧⌘R, ⌘0 / ⌘+ / ⌘−, ⌘[ and ⌘], ⌘P, Share,
  Services, Spelling, Merge All Windows. The Edit menu is not optional — without it
  a web view has no working ⌘C.
- **Native tabs.** `NSWindow` tabbing with the wrap's bundle identifier as the
  tabbing identifier, so AppKit's tab bar, tab overview and Window-menu items all
  work.
- **Chrome is a choice, and every choice stays a window.** Toolbar, title bar
  only, or no chrome — the last runs the page edge to edge under a transparent
  title bar with the traffic lights floating over it, and a transparent strip
  across the top keeps the window draggable (double-click there zooms, per the
  system setting). The strip draws the title too: the system renders it as a
  text field in the overlay above the strip, where a click on the name would
  die instead of dragging. The window gets no document proxy icon: a page URL
  isn't a file, and `representedURL` would offer a drag bound to fail.
- **Find.** WebKit's own `find(_:configuration:)`, so it's the same search Safari
  does, with WebKit's highlighting and scroll-into-view.
- **Downloads.** `WKDownload` into `~/Downloads` with a published `Progress` (Dock
  indicator, Finder's Downloads stack), collision-safe naming, and a reveal when
  it's done. Anything WebKit can't display becomes a download rather than a page of
  binary garbage.
- **Session.** `WKWebView.interactionState` — the whole back-forward list, scroll
  offset and unsubmitted form state — plus each window's frame, screen and
  full-screen state, so reopening really does put you back: on the display it was
  on, at the size it was, full screen if that's where it was quit. Not
  `NSWindowRestoration` and not frame autosave — the first is switched off by the
  system's "Close windows when quitting" setting and the second remembers one
  rectangle for the whole app — but the wrap's own session, in its own
  `UserDefaults`, one entry per window. A window whose display no longer exists at
  relaunch comes back on the screen its saved frame overlapped the most, pulled
  inside that screen's visible frame; a window quit full screen reopens at its
  last *regular* size and then goes full screen again, rather than inheriting a
  screen-sized rectangle nobody chose.
- **Link routing.** Redirects and script-driven navigation always stay in the app;
  only *user-initiated* navigation outside the wrap's hosts leaves. Extra in-app
  hosts are configurable, which is the fix for an SSO hop on another domain.
- **Handoff.** The current page is published as an `NSUserActivity`, so it can be
  picked up on an iPhone.
- **Stays out of App Nap.** A site app showing a server-driven page — a stream, an
  agent writing a reply — generates no input events of its own, so macOS naps it as
  soon as it isn't foreground: timers throttled, I/O throttled, and the WebContent
  process (the app's child) freezes mid-stream while the server carries on. The
  runtime holds a `ProcessInfo` activity (`.userInitiatedAllowingIdleSystemSleep`)
  while any window is open or a download is in flight — Safari's own exemption,
  taken by the embedder — and releases it when nothing is live, so a stay-resident
  app in the Dock still naps.
- **Dock badge.** Read out of the page title the way a browser tab does, with a
  deliberate asymmetry: a leading `(n)` takes counts up to six digits; a trailing
  one is capped at three, because `Annual Report (2024)` is a year.
- **Notifications.** A shim replaces the page's `Notification`, since WebKit exposes
  none to embedders — off by default, because replacing a page global is intrusive.
- **Sessions are per app.** Each wrap has its own bundle identifier and therefore
  its own WebKit data directory. Two wraps of one site hold two different logins.
- **A hidden window keeps the page running — and stays honest about visibility.**
  macOS does two things to a page whose window it thinks nobody is looking at that
  a wrap opts out of, and one thing it must *not* opt out of. The opt-outs live in
  `SiteWebViewFactory`.

  1. **DOM timers** are throttled to about once a second, and after a delay the
     WebContent process is suspended outright. Three undocumented `WKPreferences`
     keys turn the legacy half of that off, and the public
     `inactiveSchedulingPolicy = .none` (macOS 14) turns off the RunningBoard
     successor that would otherwise suspend a hidden page's WebContent process
     regardless of those keys. So a hidden wrap's timers keep firing at full
     speed: the title (→ Dock badge) keeps updating and notifications keep
     arriving. Whether a *stream* keeps flowing while hidden is the site's own
     choice (item 3).
  2. **App Nap** on the app process, held off with a `ProcessInfo` activity — see
     the bullet above.
  3. **Page visibility is reported honestly — deliberately.** WebKit decides
     visibility in `PageClientImpl::isViewVisible` (window present, view unhidden,
     `NSWindow.isVisible`, occlusion state), and the transitions become the page's
     `visibilitychange` events. Two earlier fixes faked this state —
     `_windowOcclusionDetectionEnabled` false, and a window subclass reporting
     `isVisible` true forever — so `document.visibilityState` was pinned to
     `"visible"` and `visibilitychange` never fired. That *caused* the freeze it
     meant to fix: streams die for reasons no embedder switch controls (a system
     sleep cuts every TCP connection — idle sleep is deliberately allowed —
     networks change, idle connections time out), and the became-visible edge is
     exactly the signal a modern site uses to resynchronise. A page that is never
     told it was hidden is never told it is visible again either, so it sat on
     stale state until a manual reload. Honest visibility restores the browser
     contract: the site pauses what it chooses while hidden — its unthrottled
     timers keep everything else running — and catches up on its own the moment
     the user comes back, the way it does in Safari.

  The cost of the opt-outs is battery when a wrap is hidden; that is the point.
  They ride undocumented WebKit keys set via KVC — fine under Developer ID
  distribution, but re-review before any Mac App Store submission.

  Release check: open a streaming page in a wrap and, for each of covered,
  miniaturised, background native tab, ⌘H-hidden, display sleep/wake and a full
  system sleep, leave it away long enough to matter (for system sleep, long enough
  that its connections die) and confirm the page shows current state the moment it
  is back — *without a manual reload*. While hidden, a timer-driven page must keep
  advancing (title/badge updates keep arriving). The unit tests pin the keys
  (`SiteWebViewFactoryTests`) and the honest window answers (`SiteWindowTests`),
  not WebKit's behaviour or App Nap. A key retired
  upstream only shows up on the macOS that retired it, so run the suite on the
  oldest supported macOS and a current beta before a release — and run the check
  with a site users actually wrap, not only a timer-driven test page.

---

## 6. Module layout

```
Wrapybara/
  WrapybaraApp.swift        @main; dispatches on LaunchMode
  LaunchMode.swift          builder or site, decided from Info.plist
  Model/                    Wrap, WrapBehavior, Boost, BoostMatch, BoostTheme,
                            WrapIcon, IconPlate, WrapConfiguration, WrapLibrary,
                            Preferences, ColorHex, DecodingDefaults
  Boosts/                   BoostMatcher, BoostCSSGenerator, BoostInjector,
                            BoostScripts (the injected JS)
  Store/                    AppSupport (paths), JSONFileStore, WrapStore
  Export/                   InfoPlistBuilder, AppBundleWriter, IcnsWriter,
                            CodeSigner, WrapExporter, AppNameSanitizer,
                            BundleIdentifierGenerator, ExtendedAttributes
  Icons/                    SiteMarkupParser, SiteIconFetcher, IconCandidate,
                            IconComposer, PlatePattern
  Site/                     SiteAppDelegate, SiteWindowController,
                            SiteWebController, SiteWebViewFactory, SiteMenuBuilder,
                            NavigationPolicy, URLNormalizer, DownloadCoordinator,
                            FindBarController, BadgeFromTitle, NotificationBridge,
                            SessionStore, ConfigurationWatcher, SiteSettings…
  Builder/                  BuilderAppDelegate, BuilderMenuBuilder,
                            LibraryWindowController, LibraryModel, LibraryView,
                            WrapEditorView, BehaviorEditorView, BoostsTabView,
                            BoostEditorView, BoostPreviewController/View,
                            NewWrapView, BuilderSettingsView, CodeEditor
  Updates/                  the shared GitHub-release updater
  Common/                   ProcessRunner
```

The split that matters: **everything decidable is pure and tested.** URL matching,
CSS generation, navigation policy, badge parsing, name and identifier sanitising,
`Info.plist` construction, markup parsing, icon ranking. The web view, the file
system and `codesign` are pushed to the edges.

---

## 7. Phases

**Phase 1 — foundation (this milestone).** Repo, CI, model, boosts, exporter, site
runtime, builder UI, tests, docs. Wrapping a site produces a signed, launchable app
with boosts that apply live.

**Phase 2 — the editing loop.** Undo in the boost editor. A boost gallery of
presets (dark, readable, no-cookie-banner) shipped with the app. Diffable "what did
this boost change?" view. Multi-select zap.

**Phase 3 — content control.** `WKContentRuleList` for a built-in tracker/banner
blocker per wrap. Per-wrap cookie and storage inspection and clearing.

**Phase 4 — more app.** AppleScript/`NSUserActivity` scripting dictionary. Custom
per-wrap global hotkeys. A menu-bar mode for wraps that want to be a popover.
Multiple named profiles per wrap (work/personal) as separate bundle identifiers.

**Phase 5 — distribution.** Developer ID + notarization for Wrapybara itself.
Sparkle or the existing updater with signature verification.

**Phase 6 — a second engine.** A `SiteWebViewFactory` sibling backed by Servo,
behind a per-wrap engine setting, revisited when Servo's platform coverage makes it
honest. Boosts port unchanged because they are CSS text and selectors, not WebKit
calls. The §2 blockers are the gate: NSView-less hosting, per-wrap storage
isolation, and a bundle layout that has to carry the engine into every generated
app. The spike comes first; the setting ships only behind a backend that passes
the manual verification list.

---

## 8. Deliberate non-goals

- **Not a browser.** No omnibox, no history UI, no bookmarks, no extensions. A wrap
  that grows into a bad browser has failed.
- **No engine bundled.** See §2.
- **No cloud, no account, no telemetry.** The library is a JSON file you can read.
- **Not sandboxed, and can't be.** Writing `.app` bundles and running `codesign` are
  both impossible under the sandbox. The App Store is therefore out of scope for
  the builder. The apps it *generates* have no such constraint in principle, but
  they aren't sandboxed either — see `PRIVACY.md`.

---

## Sources

- Arc Boosts — <https://resources.arc.net/hc/en-us/articles/19212718608151-Boosts-Customize-Any-Website>
- Zen boosts & site customization — <https://deepwiki.com/zen-browser/desktop/3.7.4-boosts-and-site-customization>
- Servo embedding API and 0.1.0 on crates.io — <https://servo.org/blog/2024/01/19/embedding-update/>, <https://servo.org/>
- Unite — <https://www.bzgapps.com/unite> · Coherence X — <https://www.bzgapps.com/coherence> · WebCatalog — <https://webcatalog.io/>
