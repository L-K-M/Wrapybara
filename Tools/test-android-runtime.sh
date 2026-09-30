#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# The runtime classes with no Android dependency, each with a JVM test.
pure_classes=(AndroidNavigationPolicy AndroidPageColors AndroidPullGesture)
sources=()
for name in "${pure_classes[@]}"; do
    cp "$repo_root/Wrapybara/Export/$name.java.txt" "$test_dir/$name.java"
    sources+=("$test_dir/$name.java" "$repo_root/AndroidRuntime/${name}Test.java")
done
javac -d "$test_dir" "${sources[@]}"
for name in "${pure_classes[@]}"; do
    java -cp "$test_dir" "ch.lkmc.wrapybara.runtime.${name}Test"
done
