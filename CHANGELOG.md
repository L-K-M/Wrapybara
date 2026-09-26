# Changelog

## Unreleased

- A site app's page keeps updating while its window is covered by another
  app, miniaturised, hidden with ⌘H or parked on a background tab, instead of
  stalling until a reload. On macOS 14 and later it also opts out of
  RunningBoard's suspension of hidden web content. Known limitation: the page
  is never told it was hidden, so after a system sleep drops its connection, a
  streaming page may still need a manual reload.

Earlier history lives in the commit log and any GitHub releases.
