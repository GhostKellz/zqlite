#!/bin/sh
# Stress test - rapid connection cycling and heavy queries
set -e

ZIG=/opt/zig-dev/zig
cd /workspace/zqlite

echo "=== ZQLite Stress Test ==="
echo ""

echo "--- 1. Rapid connection cycles (100x) ---"
$ZIG build test-memory-leaks

echo ""
echo "--- 2. Heavy query load ---"
$ZIG build test-comprehensive-memory

echo ""
echo "--- 3. Concurrent operations simulation ---"
$ZIG build test-comprehensive

echo ""
echo "--- 4. Benchmark under load ---"
$ZIG build bench-validate

echo ""
echo "=== Stress test complete ==="
