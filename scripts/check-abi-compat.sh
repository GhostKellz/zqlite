#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/prior-zqlite-source-package.tar.gz" >&2
    exit 64
fi

ARCHIVE="$1"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "prior release archive not found: $ARCHIVE" >&2
    exit 66
fi

CACHE_DIR="$ROOT/.zig-cache"
mkdir -p "$CACHE_DIR"
SCRATCH_DIR="$(mktemp -d "$CACHE_DIR/zqlite-abi-compat.XXXXXX")"
cleanup() {
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

tar -xzf "$ARCHIVE" -C "$SCRATCH_DIR"

if [[ -f "$SCRATCH_DIR/package/include/zqlite_c.symbols" ]]; then
    sort -u "$SCRATCH_DIR/package/include/zqlite_c.symbols" > "$SCRATCH_DIR/prior-symbols"
elif [[ -f "$SCRATCH_DIR/package/lib/libzqlite_c.so" ]]; then
    nm -D --defined-only "$SCRATCH_DIR/package/lib/libzqlite_c.so" \
        | awk '$3 ~ /^zqlite_/ { print $3 }' | sort -u > "$SCRATCH_DIR/prior-symbols"
else
    echo "prior archive has no zqlite_c symbol manifest or shared library" >&2
    exit 65
fi

sort -u "$ROOT/include/zqlite_c.symbols" > "$SCRATCH_DIR/current-symbols"

if comm -23 "$SCRATCH_DIR/prior-symbols" "$SCRATCH_DIR/current-symbols" > "$SCRATCH_DIR/removed-symbols" && [[ -s "$SCRATCH_DIR/removed-symbols" ]]; then
    echo "C ABI compatibility check failed; current manifest removed prior symbols:" >&2
    cat "$SCRATCH_DIR/removed-symbols" >&2
    exit 1
fi

echo "C ABI compatibility check passed against $ARCHIVE"
