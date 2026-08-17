# CI/CD

Wrapybara is a Swift/Xcode macOS app with no dependencies. CI builds and tests it on
every change, and the release workflow produces an unsigned, ad-hoc-codesigned `.app`
packaged as a `.zip` and `.dmg`, then publishes a GitHub Release.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Pull requests and pushes to `main` | Build and test the app with a pinned Xcode toolchain. |
| `.github/workflows/release.yml` | Pushing a `v*` tag (e.g. `v1.2.0`) | Build an unsigned `.app`, package `.zip` + `.dmg`, and publish a GitHub Release. |
| `.github/workflows/zai-code-review.yml` | Pull requests from the same repo | Automated review. Skips silently when `ZAI_API_KEY` isn't configured. |

## Continuous integration (`ci.yml`)

Runs a single **Build & Test** job on `macos-14`. In-progress runs for the same ref
are cancelled when a new commit is pushed.

- Selects **Xcode 16.2** via `maxim-lobanov/setup-xcode` — pinned so a runner-image
  bump can't silently change the toolchain.
- Installs `xcbeautify` (for readable build logs).
- Runs `xcodebuild clean test` against the `Wrapybara` scheme in
  `Wrapybara.xcodeproj`, destination `platform=macOS`, with
  `CODE_SIGNING_ALLOWED=NO`, writing results to `TestResults.xcresult`.
- On failure, uploads `TestResults.xcresult` as an artifact named `TestResults`.

Every action is pinned to a commit SHA: a mutable tag can be repointed at tampered
code, a SHA cannot.

### Running CI checks locally

```sh
set -o pipefail
xcodebuild \
  -project Wrapybara.xcodeproj \
  -scheme Wrapybara \
  -destination 'platform=macOS' \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  clean test | xcbeautify
```

This requires Xcode 16.2 to match CI exactly. `xcbeautify` is optional (install with
`brew install xcbeautify`); drop the pipe to use raw `xcodebuild` output.

The test suite needs no network and no GUI session: everything that touches a web
view, a window, `codesign` or the network is pushed to the edges and left
un-unit-tested on purpose (see `AGENTS.md` → Testing Notes).

## Releases (`release.yml`)

To cut a release:

```
git tag v1.2.3
git push origin v1.2.3
```

Or use the helper, which also bumps the committed `MARKETING_VERSION` so local/dev
builds (and the in-app update checker) report the same number, then creates and
pushes the tag:

```
scripts/release.sh 1.2.3 --push
```

The version is derived from the tag with the leading `v` stripped (e.g. `v1.2.3` →
`1.2.3`), and the build number is the workflow run number. The job runs on `macos-14`
with Xcode 16.2.

It produces:

- An **unsigned** Release build of `Wrapybara.app` (`CODE_SIGNING_ALLOWED=NO`), with
  `MARKETING_VERSION` set from the tag.
- The app is then **ad-hoc codesigned** (`codesign --force --deep --sign -`). This is
  not a Developer ID signature and the app is not notarized — it is only required so
  the app can launch on Apple Silicon.
- A `Wrapybara-<version>.zip` (via `ditto`) and a `Wrapybara-<version>.dmg` (via
  `create-dmg`).

Both files are attached to a GitHub Release (named `Wrapybara <version>`, with
auto-generated notes) via `softprops/action-gh-release`. The release body explains
that, because the app is **unsigned and un-notarized, macOS Gatekeeper warns on first
launch**, and tells users to right-click → Open or run
`xattr -dr com.apple.quarantine /Applications/Wrapybara.app`.

After publishing, the job **downloads what GitHub actually serves for the tag and
byte-compares it** against what was built. A mismatched asset is deleted and the run
fails — the in-app updater offers these exact bytes to every user, so a truncated
upload must not ship silently.

## The version number matters more here than usual

`MARKETING_VERSION` is stamped into every app Wrapybara builds, as both the generated
app's `CFBundleShortVersionString` and `Wrap.installedRuntimeVersion`. The library
compares that against the running Wrapybara's version to offer **Rebuild
Out-of-Date Wraps**, which is how a runtime fix reaches apps built before it.

So: a release whose version doesn't change won't prompt anyone to rebuild. Bump it.

## What CI does *not* cover

Wrapybara's own product — the apps it generates — can't be exercised in CI:

- `/usr/bin/codesign` is a Command Line Tools shim; signing a bundle needs a real
  toolchain and produces a bundle only a GUI session can launch.
- The generated app's behaviour (menus, tabs, downloads, the element picker) needs a
  window server.

Before a release, build a wrap by hand and check the manual list in `AGENTS.md` →
Testing Notes.

## Secrets

Neither `ci.yml` nor `release.yml` uses repository secrets beyond the automatically
provided `GITHUB_TOKEN` (which `action-gh-release` and the verification step use).
Releases are intentionally unsigned, so no Apple certificates or notarization
credentials are required.

`zai-code-review.yml` reads `ZAI_API_KEY` and skips itself when it's absent. It runs
on `pull_request_target` (so it can comment on PRs) and is gated to same-repository,
non-draft PRs — a privileged job must never run code from an untrusted fork.
