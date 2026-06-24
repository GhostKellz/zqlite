#!/usr/bin/env bash
set -euo pipefail

ZIG="${ZIG:-zig}"

for profile in core advanced experimental full; do
    echo "--- profile: ${profile} / Debug ---"
    "$ZIG" build test -Dprofile="$profile" --summary all
done

for optimize in ReleaseSafe ReleaseFast; do
    echo "--- optimize: ${optimize} / advanced ---"
    "$ZIG" build test -Dprofile=advanced -Doptimize="$optimize" --summary all
done

echo "Stable profile and optimized validation passed"
