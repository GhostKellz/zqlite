#!/bin/sh
# Critical path testing - file storage, persistence, concurrency, transactions
set -e

ZIG=/opt/zig/zig
cd /workspace/zqlite

echo "=== ZQLite Critical Path Tests ==="
echo ""

TESTDIR=/tmp/zqlite_critical_tests
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"

run_test() {
    name=$1
    src=$2
    echo "--- Building $name ---"
    $ZIG build-exe \
        --dep zqlite \
        -Mroot="$src" \
        -Mzqlite=src/zqlite.zig \
        -femit-bin="$TESTDIR/$name"

    echo "--- Running $name ---"
    cd "$TESTDIR"
    ./"$name"
    cd /workspace/zqlite
    echo ""
}

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
rm -rf "$TESTDIR"
rm -f /tmp/zqlite_*.db

echo ""
echo "=== ALL CRITICAL PATH TESTS PASSED ==="
