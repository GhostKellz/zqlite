#!/bin/sh
# File-backed storage validation
# Tests disk I/O, persistence, and metadata serialization
set -e

ZIG=/opt/zig-dev/zig
ROOT=/workspace/zqlite
cd "$ROOT"

echo "=== File-Backed Storage Tests ==="
echo ""

BIN_DIR="$ROOT/.zig-cache/docker-file-storage/bin"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"

echo "--- Building file storage test ---"
$ZIG build-exe \
    --dep zqlite \
    -Mroot=tests/standalone/test_file_backed.zig \
    -Mzqlite=src/zqlite.zig \
    -femit-bin="$BIN_DIR/test_file_backed"

echo ""
echo "--- Running file storage tests ---"
"$BIN_DIR/test_file_backed"

echo ""
echo "--- Cleanup ---"
rm -rf "$BIN_DIR"

echo ""
echo "=== FILE STORAGE TESTS PASSED ==="
