#!/bin/sh
# Full validation - everything we've got
set -e

ZIG=/opt/zig-dev/zig
cd /workspace/zqlite

echo "=== ZQLite Full Validation Suite ==="
echo ""

echo "--- Format check ---"
$ZIG fmt --check src/
$ZIG fmt --check tests/
$ZIG fmt --check examples/
echo "OK"

echo ""
echo "--- Core build ---"
$ZIG build
echo "OK"

echo ""
echo "--- Unit tests ---"
$ZIG build test --summary all

echo ""
echo "--- Quick validation ---"
$ZIG build test-quick

echo ""
echo "--- Security tests ---"
$ZIG build test-security

echo ""
echo "--- Comprehensive tests ---"
$ZIG build test-comprehensive

echo ""
echo "--- Advanced tests ---"
$ZIG build test-advanced

echo ""
echo "--- C API tests ---"
$ZIG build test-c-api

echo ""
echo "--- Memory leak tests ---"
$ZIG build test-memory-leaks

echo ""
echo "--- Comprehensive memory ---"
$ZIG build test-comprehensive-memory

echo ""
echo "--- Benchmark validation ---"
$ZIG build bench-validate

echo ""
echo "--- File-backed storage tests ---"
sh /workspace/zqlite/docker/scripts/test-file-storage.sh

echo ""
echo "--- Critical path tests ---"
sh /workspace/zqlite/docker/scripts/test-critical.sh

echo ""
echo "=== ALL VALIDATION PASSED ==="
