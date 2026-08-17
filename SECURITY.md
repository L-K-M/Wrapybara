# Security

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/L-K-M/Wrapybara/security/advisories/new)
for anything sensitive, or a normal issue for anything that isn't. There is no
bounty; there is a fix and credit.

## Threat model

Wrapybara writes executable application bundles and signs them, and the apps it
builds run arbitrary websites and can run user-supplied JavaScript against them.
That's a wider surface than a typical utility, so the interesting parts are spelled
out.

### Code Wrapybara produces

- **Every generated app is signed.** A bundle's signature seals its `Info.plist`,
  and the exporter writes a new one, so the copied runtime binary must be re-signed
  or macOS won't execute it on Apple Silicon. Ad-hoc by default; a Developer ID if
  you have one. There is deliberately no "skip signing" path.
- **The signature is verified after signing** (`codesign --verify --deep --strict`).
  A `codesign` that exits 0 but leaves an invalid seal would otherwise surface only
  as an app that dies silently on launch.
- **Bundles are assembled in a temporary directory and swapped into place.** A
  failure halfway through can't leave a broken `.app` in `/Applications`, and
  replacing a wrap you have running is one directory swap.
- **Inherited quarantine is stripped before signing.** `FileManager` copies extended
  attributes, so a Wrapybara that was itself opened via right-click → Open would
  otherwise pass `com.apple.quarantine` on to every app it built.
- **Wrapybara deliberately does not set `LSFileQuarantineEnabled`.** It would
  quarantine every bundle Wrapybara writes and Gatekeeper would block them all.

### Boost JavaScript

This is the sharpest edge in the product, and it is gated rather than hidden.

- A boost's script runs **in the page, in that site's origin, with access to whatever
  the app is signed into**. A malicious script in a boost for your mail app can read
  your mail.
- **Imported boosts start untrusted.** `Boost`'s decoder defaults
  `isJavaScriptTrusted` to `false` regardless of what the file says, so a script only
  runs after you have looked at it and pressed the button. Imported boosts also
  arrive switched off.
- **Export clears the trust flag**, so a boost you share arrives inert.
- Each boost's script is wrapped in its own IIFE with a `try`/`catch`, so one boost
  can't break the ones after it and its top-level declarations stay out of the page's
  global scope.
- **Scripts run in the main frame only** (`forMainFrameOnly: true`). Running a boost
  in every third-party iframe would quietly widen what you enabled.
- CSS is not gated: it can restyle a page but cannot read it.

### Injection surfaces

Boost values end up inside a stylesheet and inside a JavaScript string literal, so
both directions are handled:

- **Into CSS:** a colour that doesn't parse as hex emits no declaration; a font stack
  containing `;`, `{`, `}` or a comment marker is rejected; a zap selector containing
  a brace, semicolon, newline, comment marker or a leading/trailing comma is
  **dropped, not escaped** — escaping would give something that no longer selects
  what you picked. A boost's name is written into a CSS comment with `*/`
  neutralised.
- **Into JavaScript:** the stylesheet is embedded via `JSONSerialization`, so quotes,
  backslashes and the U+2028/U+2029 line separators (which terminate a line in
  JavaScript but not in JSON) all come out escaped. `RuntimeScriptTests` round-trips
  a deliberately hostile stylesheet through the literal.
- **From the page:** every `WKScriptMessageHandler` payload is re-validated —
  the picker's selector, the notification shim's fields (length-capped, newlines
  collapsed), the navigation reporter's URL. These arrive from page JavaScript, which
  may be the site's rather than yours.

### Network handling

- **A fetched page is never executed.** `SiteMarkupParser` scans markup as text. The
  obvious alternative — load it into a `WKWebView` and ask the DOM for the icon URL —
  would mean running a page you only typed the address of.
- Icon fetches use an **ephemeral** URL session (no cookies), a request timeout, and
  a hard cap on response size, so a `rel=icon` pointed at a video can't be buffered.
- Only `http`, `https` and `data:` icon URLs are followed; `javascript:` and friends
  are rejected at resolution.
- The update path validates the downloaded asset's size against the release metadata
  before the file leaves the private session directory, and writes to a
  non-colliding name in `~/Downloads` using an `lstat`-based existence check, so a
  dangling symlink can't redirect the write.

### Navigation

- `file:` URLs from a remote page are **blocked** outright.
- Only *user-initiated* navigation to a host outside the wrap leaves for the browser.
  A permissive rule here would break SSO; a stricter one would turn a site app into
  a browser.
- A wrap's own origins may request camera and microphone; anything else is denied
  without a prompt, so a third-party embed can't raise a permission dialog that
  appears to come from the app.

### Supply chain

- **No dependencies.** Nothing to audit, pin or wait on.
- Every GitHub Action is **pinned to a commit SHA**, including in the privileged
  review workflow. Mutable tags can be repointed at tampered code.
- `release.yml` checks out with `persist-credentials: false` — nothing in that job
  runs `git` after checkout, so a `contents: write` token shouldn't sit in
  `.git/config` for the whole build.
- The release job **byte-compares what GitHub serves against what it built**, and
  deletes a mismatched asset before failing. The in-app updater offers those exact
  bytes to every user.
- `zai-code-review.yml` runs on `pull_request_target` (privileged) and is gated to
  non-draft PRs from this repository, never a fork.

## What is *not* protected

Stated plainly, because a security document that only lists wins is not useful:

- **Releases are not notarized**, and are only ad-hoc signed. Gatekeeper warns on
  first launch and you are trusting the download.
- **The updater does not verify a signature or Team ID** on what it downloads. It
  checks the size against GitHub's metadata over TLS, and it reveals the file in
  Finder rather than installing it — but that is integrity, not authenticity.
- **Wrapping a site does not harden it.** A wrap loads the real page in a real
  engine; its trackers and third-party scripts work exactly as they would in Safari.
- **A boost you did not write is code you did not review.** The trust gate makes that
  a decision instead of an accident; it cannot make the decision for you.
- **Wrapybara is not sandboxed and cannot be** (it writes bundles and runs
  `codesign`). Generated apps aren't sandboxed either.
