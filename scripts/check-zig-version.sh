#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"

required_version="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon")"
if [[ -z "$required_version" ]]; then
    echo "could not read minimum_zig_version from build.zig.zon" >&2
    exit 1
fi

actual_version="$($ZIG version)"
if [[ "$actual_version" != "$required_version" ]]; then
    echo "Zig toolchain mismatch: required $required_version, found $actual_version" >&2
    echo "Set ZIG to the pinned compiler before building or formatting ZQLite." >&2
    exit 1
fi

echo "Zig toolchain verified: $actual_version"
