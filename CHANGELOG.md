# Changelog

## Unreleased

- Update checks now use the shared Updraft package, like the sibling apps.
  Downloads are verified (HTTPS GitHub hosts including redirects, exact size,
  SHA-256 when the release publishes one) and carry the quarantine attribute
  so Gatekeeper checks them, and assets for another OS or of an unknown type
  are no longer offered. A failed download shows an alert offering the release
  page instead of opening it silently. Check for Updates during a background
  check is reported instead of dropped, Skip This Version survives a re-tag,
  the release page opened is always Wrapybara's GitHub page, and the daily
  check runs at 90% of the interval so a punctual timer no longer skips a day.
  Generated site apps still never check for updates.
- Site app downloads whose suggested name starts with dots lose the leading
  dots, and very long names are shortened to 200 bytes.
- Exported Android apps drop their toolbar. The page fills the screen under
  system bars coloured to match it; pull down from the top of a page to reload,
  and long-press the app icon for Home, Reload and Open in browser.
- A site app's page keeps updating while its window is covered by another
  app, miniaturised, hidden with ⌘H or parked on a background tab, instead of
  stalling until a reload. On macOS 14 and later it also opts out of
  RunningBoard's suspension of hidden web content. Known limitation: the page
  is never told it was hidden, so after a system sleep drops its connection, a
  streaming page may still need a manual reload.

Earlier history lives in the commit log and any GitHub releases.
