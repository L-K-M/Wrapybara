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
  (`library.json`, `Runtime/<uuid>.json`, `Icons/<uuid>.png` plus the
  un-composited `Icons/<uuid>-artwork.png` the plate restyler recomposes from);
  app-level settings in `UserDefaults`.
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
  `URLNormalizer`, `IconCandidate.ranked`, `PlatePattern` and
  `WindowGeometry.resolvedFrame` take values and
  return values. That's
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
- **A site app must hold a `ProcessInfo` activity while a window or download is
  live** (`SiteAppDelegate.updateAppNapExemption`). Without it App Nap throttles the
  app and its WebContent child once the app isn't foreground, and server-driven
  pages freeze mid-stream — the "app stopped updating but the server kept running"
  bug. `.userInitiatedAllowingIdleSystemSleep` only; nothing that pins the display
  or system awake.
- **A covered window must not mark its page hidden**
  (`SiteWebViewFactory.keepPageVisibleWhileWindowIsCovered`). The App Nap activity
  and the three `WKPreferences` throttling keys are not enough on their own: WebKit
  computes visibility in `PageClientImpl::isViewVisible`, and losing
  `NSWindowOcclusionStateVisible` alone suspends `requestAnimationFrame`, suspends
  the CSS/SVG animation timelines and fires `visibilitychange` — which is the
  *other* half of the same bug, and the half that makes a chat page need a reload
  rather than just catch up. Setting `WKWebView`'s
  `_windowOcclusionDetectionEnabled` false is what removes it.
- **A window hidden with ⌘H, or a background native tab, must not mark its page
  hidden either** (`SiteWindow`). Both make `NSWindow.isVisible` false while the
  app is still frontmost — no WebKit switch reaches that check (a miniaturised
  window stays ordered in and is covered by the occlusion switch above), so
  site-app windows override `isVisible` to report visible until their close begins,
  then answer honestly again for AppKit's quit/reopen logic.
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
  ⌘L, ⌘P; quitting and reopening — the page *and* the window come back: frame,
  screen and full screen, including a quit in full screen (the window must reopen
  at its last regular size and then re-enter full screen) and a relaunch with the
  display the window was on unplugged (the window must land wholly on the screen
  it overlapped most, visible frame honoured), and both with several windows on
  different displays; a wrap with *No chrome* — the
  window must drag from the top strip and from the title name (including from
  an unfocused state),
  double-click there must follow the system title-bar setting, and no document
  proxy icon may appear next to the title; editing a boost while the built
  app is running; the element picker on a single-page app; Show Web Inspector
  (⌥⌘I) — it must open in its own window with nothing flickering, because an
  *attached* inspector fights the container's Auto Layout; a wrap built by an older
  version (the rebuild prompt); a streaming page (e.g. a chat) that keeps updating
  *and animating* while another app's window covers it, that keeps updating while
  miniaturised and while parked on a background tab, and that catches up without
  a reload after a display sleeps and wakes; a failed navigation with an
  *everywhere*-scoped boost switched on (the Dark preset will do) — the error page
  must keep its own styling, and Try Again must land on a page that has the boost
  back. `SiteWebController` can't be unit-driven without a live `WKWebView`, so this
  one is only ever caught by eye.

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

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
