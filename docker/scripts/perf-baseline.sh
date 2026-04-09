#!/bin/sh
# Performance baseline - capture metrics
set -e

ZIG=/opt/zig/zig
cd /workspace/zqlite

echo "=== ZQLite Performance Baseline ==="
echo ""

echo "--- Benchmark suite ---"
$ZIG build bench-validate

echo ""
echo "--- Timed test runs ---"

echo -n "Core tests: "
START=$(date +%s%N)
$ZIG build test --summary all >/dev/null 2>&1
END=$(date +%s%N)
echo "$((($END - $START) / 1000000))ms"

echo -n "Security tests: "
START=$(date +%s%N)
$ZIG build test-security >/dev/null 2>&1
END=$(date +%s%N)
echo "$((($END - $START) / 1000000))ms"

echo -n "Memory tests: "
START=$(date +%s%N)
$ZIG build test-memory-leaks >/dev/null 2>&1
END=$(date +%s%N)
echo "$((($END - $START) / 1000000))ms"

echo -n "Comprehensive: "
START=$(date +%s%N)
$ZIG build test-comprehensive >/dev/null 2>&1
END=$(date +%s%N)
echo "$((($END - $START) / 1000000))ms"

echo ""
echo "=== Performance baseline complete ==="
