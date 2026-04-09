#!/bin/sh
# Chaos test - run tests repeatedly to catch flaky issues
set -e

ZIG=/opt/zig/zig
cd /workspace/zqlite

ITERATIONS=${1:-5}

echo "=== ZQLite Chaos Test ($ITERATIONS iterations) ==="
echo ""

i=1
while [ $i -le $ITERATIONS ]; do
    echo "--- Iteration $i/$ITERATIONS ---"

    $ZIG build test --summary all >/dev/null 2>&1 && echo "  core: OK" || { echo "  core: FAILED"; exit 1; }
    $ZIG build test-security >/dev/null 2>&1 && echo "  security: OK" || { echo "  security: FAILED"; exit 1; }
    $ZIG build test-memory-leaks >/dev/null 2>&1 && echo "  memory: OK" || { echo "  memory: FAILED"; exit 1; }

    i=$((i + 1))
done

echo ""
echo "=== Chaos test passed ($ITERATIONS iterations, no flakes) ==="
