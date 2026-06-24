#!/bin/sh
set -eu

ZIG="${ZIG:-zig}"
ROOT="${ROOT:-$PWD}"
CACHE_DIR="${ZQLITE_VALGRIND_CACHE_DIR:-$ROOT/.zig-cache/valgrind}"
BIN_DIR="$CACHE_DIR/bin"
VALGRIND_LOG_DIR="$CACHE_DIR/logs"
TESTS="${ZQLITE_VALGRIND_TESTS:-test_security test_upsert test_file_backed test_transaction_atomicity test_index_persistence}"

rm -rf "$BIN_DIR" "$VALGRIND_LOG_DIR"
mkdir -p "$BIN_DIR" "$VALGRIND_LOG_DIR"

build_test() {
    name=$1
    src=$2
    "$ZIG" build-exe \
        -target x86_64-linux-musl \
        -mcpu x86_64_v2 \
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
echo "Scratch: $CACHE_DIR"
echo "Tests: $TESTS"
echo

source_for_test() {
    case "$1" in
        test_security) echo "tests/standalone/test_security.zig" ;;
        test_upsert) echo "tests/standalone/test_upsert.zig" ;;
        test_file_backed) echo "tests/standalone/test_file_backed.zig" ;;
        test_transaction_atomicity) echo "tests/standalone/test_transaction_atomicity.zig" ;;
        test_concurrent_access) echo "tests/standalone/test_concurrent_access.zig" ;;
        test_index_persistence) echo "tests/standalone/test_index_persistence.zig" ;;
        *)
            echo "unknown valgrind test: $1" >&2
            exit 64
            ;;
    esac
}

for test_name in $TESTS; do
    build_test "$test_name" "$(source_for_test "$test_name")"
done

for test_name in $TESTS; do
    run_valgrind "$test_name"
done

rm -rf "$BIN_DIR"
rm -rf "$VALGRIND_LOG_DIR"

echo "=== Valgrind audit passed ==="
echo "Audited tests: $TESTS"
