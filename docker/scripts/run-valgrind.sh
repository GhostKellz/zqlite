#!/bin/sh
set -eu

ZIG=/opt/zig/zig
ROOT=/workspace/zqlite
BIN_DIR=/tmp/zqlite-valgrind
VALGRIND_LOG_DIR=/tmp/zqlite-valgrind-logs

mkdir -p "$BIN_DIR"
mkdir -p "$VALGRIND_LOG_DIR"
rm -f "$BIN_DIR"/*
rm -f "$VALGRIND_LOG_DIR"/*
rm -f /tmp/zqlite_*.db

build_test() {
    name=$1
    src=$2
    "$ZIG" build-exe \
        -target x86_64-linux-musl \
        -mcpu x86_64_v2 \
        -fstrip \
        --dep zqlite \
        -Mroot="$src" \
        -Mzqlite=src/zqlite.zig \
        -femit-bin="$BIN_DIR/$name"
}

run_valgrind() {
    name=$1
    echo "--- Valgrind: $name ---"
    log_file="$VALGRIND_LOG_DIR/$name.log"
    valgrind \
        --quiet \
        --leak-check=full \
        --show-leak-kinds=all \
        --track-origins=yes \
        --error-exitcode=1 \
        --log-file="$log_file" \
        "$BIN_DIR/$name"
    grep -E "ERROR SUMMARY|in use at exit|All heap blocks were freed|definitely lost|indirectly lost|possibly lost|still reachable" "$log_file" || true
    echo
}

cd "$ROOT"

echo "=== ZQLite Valgrind Audit ==="
echo

build_test "test_security" "tests/standalone/test_security.zig"
build_test "test_file_backed" "tests/standalone/test_file_backed.zig"
build_test "test_transaction_atomicity" "tests/standalone/test_transaction_atomicity.zig"
build_test "test_concurrent_access" "tests/standalone/test_concurrent_access.zig"
build_test "test_index_persistence" "tests/standalone/test_index_persistence.zig"

run_valgrind "test_security"
run_valgrind "test_file_backed"
run_valgrind "test_transaction_atomicity"
run_valgrind "test_concurrent_access"
run_valgrind "test_index_persistence"

rm -rf "$BIN_DIR"
rm -rf "$VALGRIND_LOG_DIR"
rm -f /tmp/zqlite_*.db /tmp/zqlite_critical_tests/*.db 2>/dev/null || true

echo "=== Valgrind audit passed ==="
echo "Audited tests: security, file-backed, transaction atomicity, concurrent access, index persistence"
