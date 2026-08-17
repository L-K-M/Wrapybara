# Privacy

Wrapybara has no account, no telemetry, no analytics and no server of its own.
This document says exactly what it stores and what talks to the network — including
the things it *can't* promise, because the apps it builds load websites, and websites
do what websites do.

## What Wrapybara stores, and where

Everything is on your Mac, in files you can read.

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Wrapybara/library.json` | Your wraps: name, address, bundle identifier, behaviour settings, boosts (including any CSS and JavaScript you wrote), and where each built app is on disk. |
| `~/Library/Application Support/Wrapybara/Runtime/<uuid>.json` | One resolved configuration per wrap. This is the copy a running app reads, and it duplicates that wrap's boosts. |
| `~/Library/Application Support/Wrapybara/Icons/<uuid>.png` | The composed artwork for each wrap. |
| `~/Library/Preferences/com.wrapybara.Wrapybara.plist` | Where to build apps, the signing identity you chose, icon style, and the after-build toggles. |

These are plain JSON and PNG. Delete the folder and Wrapybara forgets everything;
the apps it already built keep working, because each one carries a copy of its own
configuration inside its bundle.

## What each generated app stores

A generated app has its own bundle identifier, so macOS gives it its own storage,
separate from Wrapybara's and from every other wrap's:

- **Its WebKit data** — cookies, local storage, IndexedDB, caches, service workers —
  in the standard per-app WebKit location. This is why two wraps of the same site can
  be two different accounts, and why signing out of one doesn't sign out the other.
- **Its session**, in its own `UserDefaults`: a `WKWebView.interactionState` blob per
  window, which carries the back-forward list, scroll position and unsubmitted form
  contents so the app can reopen where you left it. Turn off *Reopen where I left
  off* and nothing is stored.
- **A copy of its configuration**, baked into `Contents/Resources/wrap.json` at build
  time.

Nothing about a wrap's browsing is reported anywhere. There is no history file.

## Network access

Wrapybara itself makes exactly two kinds of request:

1. **Icon and name discovery**, when you add a wrap or use *Refresh Icon from Site*.
   It fetches the page, its web app manifest if it has one, and candidate icon files
   — from the site you typed and whatever host that site points its icons at. It
   sends a plain desktop-Safari `User-Agent` and no cookies (an ephemeral session),
   and it **never runs the page**: the markup is scanned as text rather than loaded
   into a web view, precisely so that fetching a page you typed doesn't execute it.
2. **The update check**, against `api.github.com` for this repository's releases —
   unauthenticated, once a day at most, and switchable off. If you choose to
   download an update it comes from `objects.githubusercontent.com`. No identifiers
   are sent beyond what any HTTP request carries; the `User-Agent` is the app's
   bundle identifier, which GitHub's API requires.

**The apps Wrapybara builds are a different matter, and this is the honest part:** a
wrap loads a real website in a real browser engine. That site sees your IP address,
sets its own cookies, and can load third-party scripts and trackers exactly as it
would in Safari. Wrapping a site does not privacy-harden it. What a wrap *does*
change is that the site is confined to its own app's storage instead of sharing a
browser profile with everything else you have open.

## Boosts, CSS and JavaScript

- CSS in a boost restyles a page. It cannot read it.
- **JavaScript in a boost runs inside the page, in that site's origin, with access to
  whatever that app is signed into.** That is the whole point of the feature and also
  its whole risk.
- Boosts you write are trusted when you save them. Boosts that arrive by **import**
  are not: their script does not run until you have read it and said so, and they
  arrive switched off.
- **Exporting a boost clears its trust flag**, so a boost you hand to someone else
  arrives inert on their side too.
- Nothing is uploaded. There is no boost gallery and no sync; sharing a boost means
  sending someone a file.

## Notifications

*Forward the site's notifications* is **off by default**. When you turn it on for a
wrap, that app replaces the page's `Notification` object with a shim and posts what
the page asks for through macOS's notification system. Notification text is capped
in length, newlines are collapsed, and nothing is stored — but the site's own
notification content does reach Notification Center, which keeps its own history.

Turning this on also means a site that currently stays quiet — because it can detect
that notifications are unavailable — will start asking for permission.

## Permissions Wrapybara asks for

None at launch.

- **No Accessibility, no Input Monitoring, no Screen Recording, no Full Disk Access.**
- Writing to `/Applications` needs no permission for an admin account. If your
  account can't write there, Wrapybara offers `~/Applications` instead.
- macOS may ask for access to a folder you point it at, through the standard
  file-access prompt.

A generated app asks for nothing either, until a page does. If a site requests the
camera or the microphone, macOS shows its own prompt naming that app — and a wrap only
lets the site's *own* origins ask, so a third-party embed can't raise a prompt that
looks like it came from the app.

## Sandboxing

Wrapybara is **not** sandboxed and cannot be: its job is to write `.app` bundles and
run `/usr/bin/codesign` over them, and a sandboxed app can do neither. The Mac App
Store is therefore out of scope. Distribution is Developer ID + notarization with the
Hardened Runtime (today: unsigned/ad-hoc — see `CICD.md`).

The apps it generates are not sandboxed either. They are ad-hoc signed without the
Hardened Runtime, which is what lets WebKit's camera and microphone access work with
just the usage strings and the normal per-app system prompt.

## Third parties

Wrapybara has no dependencies. It bundles no analytics SDK, no crash reporter and no
advertising framework, because it bundles nothing at all.
