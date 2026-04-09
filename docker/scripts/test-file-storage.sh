#!/bin/sh
# File-backed storage validation
# Tests disk I/O, persistence, and metadata serialization
set -e

ZIG=/opt/zig/zig
cd /workspace/zqlite

echo "=== File-Backed Storage Tests ==="
echo ""

# Create temp directory for test databases
TESTDIR=/tmp/zqlite_file_tests
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"

echo "--- Building file storage test ---"
$ZIG build-exe \
    --dep zqlite \
    -Mroot=tests/standalone/test_file_backed.zig \
    -Mzqlite=src/zqlite.zig \
    -femit-bin="$TESTDIR/test_file_backed"

echo ""
echo "--- Running file storage tests ---"
cd "$TESTDIR"
./test_file_backed

echo ""
echo "--- Cleanup ---"
rm -rf "$TESTDIR"

echo ""
echo "=== FILE STORAGE TESTS PASSED ==="
