#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT/.zig-cache"
mkdir -p "$CACHE_DIR"
SCRATCH_DIR="$(mktemp -d "$CACHE_DIR/zqlite-c-api.XXXXXX")"
cleanup() {
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

sed -nE 's/^(pub[[:space:]]+)?export fn (zqlite_[a-zA-Z0-9_]+).*/\2/p' \
    "$ROOT/src/ffi/c_api.zig" | sort -u > "$SCRATCH_DIR/implementation-functions"

grep -Eo 'zqlite_[a-zA-Z0-9_]+[[:space:]]*\(' \
    "$ROOT/include/zqlite.h" | sed -E 's/[[:space:]]*\($//' | sort -u > "$SCRATCH_DIR/header-functions"

if ! diff -u "$SCRATCH_DIR/implementation-functions" "$SCRATCH_DIR/header-functions"; then
    echo "C API function declarations do not match implementation exports" >&2
    exit 1
fi

sort -u "$ROOT/include/zqlite_c.symbols" > "$SCRATCH_DIR/manifest-functions"
if ! diff -u "$SCRATCH_DIR/manifest-functions" "$SCRATCH_DIR/header-functions"; then
    echo "C API symbol manifest does not match public header" >&2
    exit 1
fi

for lib in "$ROOT"/zig-out/lib/libzqlite_c.so "$ROOT"/zig-out/release/package/lib/libzqlite_c.so; do
    if [[ -f "$lib" ]]; then
        nm -D --defined-only "$lib" \
            | awk '$3 ~ /^zqlite_/ { print $3 }' | sort -u > "$SCRATCH_DIR/library-functions"
        if ! diff -u "$SCRATCH_DIR/manifest-functions" "$SCRATCH_DIR/library-functions"; then
            echo "C API shared library exports do not match symbol manifest: $lib" >&2
            exit 1
        fi
    fi
done

sed -nE 's/^pub const (ZQLITE_[A-Z0-9_]+) = ([0-9]+);/\1 \2/p' \
    "$ROOT/src/ffi/c_api.zig" | sort -u > "$SCRATCH_DIR/implementation-constants"

sed -nE 's/^#define[[:space:]]+(ZQLITE_[A-Z0-9_]+)[[:space:]]+([0-9]+).*/\1 \2/p' \
    "$ROOT/include/zqlite.h" | sort -u > "$SCRATCH_DIR/header-constants"

if ! diff -u "$SCRATCH_DIR/implementation-constants" "$SCRATCH_DIR/header-constants"; then
    echo "C API error constants do not match implementation values" >&2
    exit 1
fi

echo "C API header matches implementation exports and constants"
