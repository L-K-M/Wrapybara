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

### Servo — genuinely interesting, not yet

Servo shipped **0.1.0 to crates.io in April 2026**, with a real embedding API
(`ServoBuilder`, a `WebView` handle, navigation and input on the handle, pixel
readback for headless use) and macOS among its supported platforms. That is a
material change from a year earlier, and it is the first credible non-WebKit,
non-Chromium option in a decade.

It is still not the right engine for **this** app's v1:

- Web-platform coverage isn't there yet for the kind of sites people wrap (rich
  editors, video conferencing, drag-and-drop file uploads).
- None of the native integration above comes with it — Keychain autofill, the share
  sheet, Look Up, system media controls would all have to be built or done without.
- Wrapybara would be back in the business of shipping an engine, including its
  security fixes.

**The plan is to keep the door open, not to walk through it now.** The runtime's
web-view usage is deliberately funnelled through `SiteWebViewFactory`,
`SiteWebController` and `BoostInjector`; a second backend means implementing that
surface, not rewriting the app. Boosts are already expressed as CSS text and
selectors rather than as WebKit calls, so they port unchanged. Phase 6 below is a
Servo backend behind a per-wrap engine setting, revisited when Servo's platform
coverage makes it honest.

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
  tinted plate derived from the site's own `theme-color`.
- **Menu bar.** App / File / Edit / View / History / Window / Help, every item
  wired: ⌘L, ⌘F with ⌘G and ⇧⌘G, ⌘R and ⇧⌘R, ⌘0 / ⌘+ / ⌘−, ⌘[ and ⌘], ⌘P, Share,
  Services, Spelling, Merge All Windows. The Edit menu is not optional — without it
  a web view has no working ⌘C.
- **Native tabs.** `NSWindow` tabbing with the wrap's bundle identifier as the
  tabbing identifier, so AppKit's tab bar, tab overview and Window-menu items all
  work.
- **Find.** WebKit's own `find(_:configuration:)`, so it's the same search Safari
  does, with WebKit's highlighting and scroll-into-view.
- **Downloads.** `WKDownload` into `~/Downloads` with a published `Progress` (Dock
  indicator, Finder's Downloads stack), collision-safe naming, and a reveal when
  it's done. Anything WebKit can't display becomes a download rather than a page of
  binary garbage.
- **Session.** `WKWebView.interactionState` — the whole back-forward list, scroll
  offset and unsubmitted form state — so reopening really does put you back.
- **Link routing.** Redirects and script-driven navigation always stay in the app;
  only *user-initiated* navigation outside the wrap's hosts leaves. Extra in-app
  hosts are configurable, which is the fix for an SSO hop on another domain.
- **Handoff.** The current page is published as an `NSUserActivity`, so it can be
  picked up on an iPhone.
- **Dock badge.** Read out of the page title the way a browser tab does, with a
  deliberate asymmetry: a leading `(n)` takes counts up to six digits; a trailing
  one is capped at three, because `Annual Report (2024)` is a year.
- **Notifications.** A shim replaces the page's `Notification`, since WebKit exposes
  none to embedders — off by default, because replacing a page global is intrusive.
- **Sessions are per app.** Each wrap has its own bundle identifier and therefore
  its own WebKit data directory. Two wraps of one site hold two different logins.
- **A covered window keeps the page running.** macOS throttles a hidden page's DOM
  timers to about once a second and, after a delay, suspends the WebContent
  process; a streaming chat then freezes the moment its window is covered or the
  display sleeps. A wrap is a single-tab app, not a background browser tab, so the
  runtime opts out of that throttling (`SiteWebViewFactory`). The cost is battery
  when a wrap is hidden; that is the point. The opt-out rides undocumented
  `WKPreferences` keys set via KVC — fine under Developer ID distribution, but
  re-review before any Mac App Store submission. Release check: open a streaming
  page in a wrap, cover or miniaturise the window for a minute, and confirm the
  stream is still live; also leave it hidden 5+ minutes with the display asleep
  and confirm a timer-driven page still advances on wake — the unit tests pin the
  preference keys, not WebKit's behaviour or App Nap.

---

## 6. Module layout

```
Wrapybara/
  WrapybaraApp.swift        @main; dispatches on LaunchMode
  LaunchMode.swift          builder or site, decided from Info.plist
  Model/                    Wrap, WrapBehavior, Boost, BoostMatch, BoostTheme,
                            WrapIcon, WrapConfiguration, WrapLibrary, Preferences,
                            ColorHex, DecodingDefaults
  Boosts/                   BoostMatcher, BoostCSSGenerator, BoostInjector,
                            BoostScripts (the injected JS)
  Store/                    AppSupport (paths), JSONFileStore, WrapStore
  Export/                   InfoPlistBuilder, AppBundleWriter, IcnsWriter,
                            CodeSigner, WrapExporter, AppNameSanitizer,
                            BundleIdentifierGenerator, ExtendedAttributes
  Icons/                    SiteMarkupParser, SiteIconFetcher, IconCandidate,
                            IconComposer
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
calls.

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
