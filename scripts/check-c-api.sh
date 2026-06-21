#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

sed -nE 's/^export fn (zqlite_[a-zA-Z0-9_]+).*/\1/p' \
    "$ROOT/src/ffi/c_api.zig" | sort -u > "$TMP_DIR/implementation-functions"

grep -Eo 'zqlite_[a-zA-Z0-9_]+[[:space:]]*\(' \
    "$ROOT/include/zqlite.h" | sed -E 's/[[:space:]]*\($//' | sort -u > "$TMP_DIR/header-functions"

if ! diff -u "$TMP_DIR/implementation-functions" "$TMP_DIR/header-functions"; then
    echo "C API function declarations do not match implementation exports" >&2
    exit 1
fi

sed -nE 's/^pub const (ZQLITE_[A-Z0-9_]+) = ([0-9]+);/\1 \2/p' \
    "$ROOT/src/ffi/c_api.zig" | sort -u > "$TMP_DIR/implementation-constants"

sed -nE 's/^#define[[:space:]]+(ZQLITE_[A-Z0-9_]+)[[:space:]]+([0-9]+).*/\1 \2/p' \
    "$ROOT/include/zqlite.h" | sort -u > "$TMP_DIR/header-constants"

if ! diff -u "$TMP_DIR/implementation-constants" "$TMP_DIR/header-constants"; then
    echo "C API error constants do not match implementation values" >&2
    exit 1
fi

echo "C API header matches implementation exports and constants"
