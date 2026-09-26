#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cp "$repo_root/Wrapybara/Export/AndroidNavigationPolicy.java.txt" "$test_dir/AndroidNavigationPolicy.java"
javac -d "$test_dir" "$test_dir/AndroidNavigationPolicy.java" \
    "$repo_root/AndroidRuntime/AndroidNavigationPolicyTest.java"
java -cp "$test_dir" com.wrapybara.runtime.AndroidNavigationPolicyTest
