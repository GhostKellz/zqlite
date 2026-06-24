#!/bin/sh
# Critical path testing - file storage, persistence, concurrency, transactions
set -e

ZIG=/opt/zig-dev/zig
ROOT=/workspace/zqlite
cd "$ROOT"

echo "=== ZQLite Critical Path Tests ==="
echo ""

BIN_DIR="$ROOT/.zig-cache/docker-critical/bin"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"

run_test() {
    name=$1
    src=$2
    echo "--- Building $name ---"
    $ZIG build-exe \
        --dep zqlite \
        -Mroot="$src" \
        -Mzqlite=src/zqlite.zig \
        -femit-bin="$BIN_DIR/$name"

    echo "--- Running $name ---"
    "$BIN_DIR/$name"
    echo ""
}

# UPSERT / ON CONFLICT excluded.* semantics
run_test "upsert" "tests/standalone/test_upsert.zig"

# Core file storage
run_test "file_backed" "tests/standalone/test_file_backed.zig"

# Large database (cache overflow)
run_test "large_database" "tests/standalone/test_large_database.zig"

# Transaction atomicity
run_test "transaction_atomicity" "tests/standalone/test_transaction_atomicity.zig"

# Concurrent access
run_test "concurrent_access" "tests/standalone/test_concurrent_access.zig"

# Index persistence
run_test "index_persistence" "tests/standalone/test_index_persistence.zig"

# Filesystem errors
run_test "filesystem_errors" "tests/standalone/test_filesystem_errors.zig"

echo "--- Cleanup ---"
rm -rf "$BIN_DIR"

echo ""
echo "=== ALL CRITICAL PATH TESTS PASSED ==="
