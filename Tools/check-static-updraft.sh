#!/usr/bin/env bash
set -euo pipefail

executable="${1:?Pass the Release app executable}"

# Exported site apps copy this executable alone. Any non-system dylib or
# framework load command would break them, even if the builder app can launch.
libraries=$(otool -arch all -L "$executable")
non_system=$(awk '/^[[:space:]]/ && $1 !~ /^\/(System\/Library|usr\/lib)\// { print $1 }' <<< "$libraries")
if [[ -n "$non_system" ]]; then
    printf 'Unexpected dynamic dependencies in %s:\n%s\n' "$executable" "$non_system" >&2
    exit 1
fi

# Check defined Swift symbols so a build with Updraft missing also fails.
architecture_list=$(lipo -archs "$executable")
read -r -a architectures <<< "$architecture_list"
for architecture in "${architectures[@]}"; do
    symbols=$(nm -arch "$architecture" -U -j "$executable")
    for module in 10UpdraftKit 11UpdraftCore; do
        if ! grep -qF "_\$s$module" <<< "$symbols"; then
            printf 'Missing static %s symbols in %s (%s)\n' "${module:2}" "$executable" "$architecture" >&2
            exit 1
        fi
    done
done
