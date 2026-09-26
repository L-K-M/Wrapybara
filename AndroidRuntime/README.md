# Android runtime

The Mac exporter compiles the two Java templates in `Wrapybara/Export/` against
Android SDK 35. Generated apps run on Android 8.0 or later. They need no connection
to Wrapybara after installation.

`assets/wrap.json` contains `name`, `homeURL`, `allowedDomains` (normalized hosts),
`openExternalLinksInBrowser`, and `restoreLastPage`. `assets/boosts.json` contains
ordered JavaScript sources for the exported Boosts. Boosts run after successful
main-frame loads; they cannot run before the site's own startup scripts.

Each package has its own cookies and storage. Only deliberate top-level external
links leave the app; redirects stay inside for sign-in. Native handoff supports
`mailto`, `tel`, `sms`, and `geo`. File access, content access, mixed content,
unverified TLS connections, and native JavaScript bridges are disabled.

Run the pure navigation tests with a JDK installed:

```bash
bash Tools/test-android-runtime.sh
```

## Device verification

Use Android 8 and Android 15 or later, with a current Android System WebView.

1. Install an exported APK. Check its name, icon, home page, keyboard, rotation,
   status/navigation bar insets, Home, Reload, and Back.
2. Sign in, force-stop, and reopen. Check the session and last page survive.
   Install a rebuilt APK over it; check the same session remains.
3. Test an SSO redirect through another host. Check external links open in the
   browser, allowed hosts stay inside, and `target="_blank"` works in the current
   view. Providers that reject embedded browsers remain unsupported.
4. Test allowed native links, plus `intent:`, `file:`, and `content:` links.
   Only a deliberate supported link should launch another app.
5. Test Boost CSS and trusted JavaScript, including SPA navigation. Disconnect
   networking and reload: the native error must appear without Boosts. Reconnect
   and choose Try again: the site and Boosts must return. Repeat with an invalid
   TLS certificate and a main-frame HTTP error.
6. Hide and restore the app; check site visibility events and normal Android
   lifecycle behavior. There is no continuous-background-update guarantee.
7. Test a download. The browser prompt explains that its session is separate.

Device checks require an emulator or phone; JVM tests do not verify WebView,
sign-in, Android lifecycle, or installation.

## First-version limits

No live Boost sync, tabs, native notifications, camera/microphone/location access,
file uploads, full-screen video controls, or in-app download manager. Downloads
open in a browser after confirmation; generated `blob:` downloads are unsupported.
Editing a Boost requires exporting and installing an updated APK. Android and
the website control background execution and visibility normally.
