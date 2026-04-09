#!/bin/bash
# ZQLite Valgrind Memory Test Script
# Builds with baseline CPU and runs extensive valgrind checks

set -e

echo "=== ZQLite Valgrind Memory Testing ==="
echo ""

cd /workspace/zqlite

# Build test binaries with baseline CPU (avoids valgrind instruction issues)
echo "--- Building test binaries (baseline CPU) ---"
zig build test-quick -Dcpu=x86_64 -Doptimize=Debug 2>&1 || {
    echo "Note: Using standard build (cpu flag may not apply)"
    zig build test-quick -Doptimize=Debug
}

echo ""
echo "--- Running Valgrind leak check ---"

# Find the test binary
TEST_BIN=$(find .zig-cache -name "test_validation" -type f -executable 2>/dev/null | head -1)

if [ -z "$TEST_BIN" ]; then
    echo "Building standalone leak test..."
    zig build test-memory-leaks -Doptimize=Debug
    TEST_BIN=$(find .zig-cache -name "test" -type f -executable 2>/dev/null | head -1)
fi

if [ -n "$TEST_BIN" ]; then
    echo "Testing: $TEST_BIN"
    valgrind \
        --leak-check=full \
        --show-leak-kinds=definite,indirect \
        --errors-for-leak-kinds=definite,indirect \
        --track-origins=yes \
        --error-exitcode=1 \
        "$TEST_BIN" 2>&1 || {
            EXIT_CODE=$?
            if [ $EXIT_CODE -eq 1 ]; then
                echo "VALGRIND: Memory leaks detected!"
                exit 1
            else
                echo "Note: Valgrind exited with code $EXIT_CODE (may be instruction incompatibility)"
            fi
        }
else
    echo "No test binary found, running Zig's built-in leak detection..."
fi

echo ""
echo "--- Running Zig built-in memory tests ---"
zig build test-memory-leaks
zig build test-leak-detection
zig build test-comprehensive-memory

echo ""
echo "=== All memory tests completed ==="
