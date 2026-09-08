#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"

required_version="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon")"
if [[ -z "$required_version" ]]; then
    echo "could not read minimum_zig_version from build.zig.zon" >&2
    exit 1
fi

# Self-hosted runners update Zig nightly. The manifest declares a lower bound,
# not an exact compiler pin; zig build enforces that minimum.
actual_version="$("$ZIG" version)"
echo "Zig compiler: $actual_version"
echo "Manifest minimum: $required_version (enforced by zig build)"
