#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_HOME:?Set ANDROID_HOME to an SDK with platform 35 and build-tools 35.0.0}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or later}"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT

compiler_options=(-swift-version 5)
if [[ -n "${SWIFT_SDK:-}" ]]; then compiler_options+=(-sdk "$SWIFT_SDK"); fi

swiftc "${compiler_options[@]}" \
    "$repo_root/Wrapybara/Common/ProcessRunner.swift" \
    "$repo_root/Wrapybara/Export/AndroidToolchain.swift" \
    "$repo_root/Wrapybara/Export/AndroidSigningPasswordStore.swift" \
    "$repo_root/Wrapybara/Export/AndroidSigningIdentity.swift" \
    "$repo_root/Wrapybara/Export/AndroidAPKBuilder.swift" \
    "$repo_root/Tools/AndroidBuildSmoke.swift" \
    -o "$test_directory/android-build-smoke"
"$test_directory/android-build-smoke" "$repo_root" "$ANDROID_HOME" "$JAVA_HOME"
