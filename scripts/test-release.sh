#!/bin/bash
# ZQLite Release Validation Script
# Runs full test coverage beyond CI defaults

set -e

ZIG="${ZIG:-zig}"

echo "=== ZQLite Release Validation ==="
echo ""

echo "--- Toolchain Check ---"
bash scripts/check-zig-version.sh
echo ""

echo "--- Format Check ---"
$ZIG fmt --check src/
$ZIG fmt --check examples/
$ZIG fmt --check tests/
echo "OK"
echo ""

echo "--- Repository and C ABI Contracts ---"
bash scripts/check-repository-hygiene.sh
bash scripts/check-c-api.sh
echo "OK"
echo ""

echo "--- Build Profiles ---"
$ZIG build -Dprofile=core
$ZIG build -Dprofile=advanced
$ZIG build -Dprofile=experimental
$ZIG build -Dprofile=full
echo "OK"
echo ""

echo "--- Build ---"
$ZIG build
echo "OK"
echo ""

echo "--- Core Tests ---"
$ZIG build test --summary all
echo ""

echo "--- Quick Tests ---"
$ZIG build test-quick
echo ""

echo "--- Security Tests ---"
$ZIG build test-security
echo ""

echo "--- Comprehensive Tests ---"
$ZIG build test-comprehensive
echo ""

echo "--- Storage Tests ---"
$ZIG build test-storage
echo ""

echo "--- Advanced Tests ---"
$ZIG build test-advanced
echo ""

echo "--- C API Tests ---"
$ZIG build test-c-api
echo ""

echo "--- Release Package Consumers ---"
bash scripts/test-release-package.sh
echo ""

echo "--- Install Script Paths ---"
bash scripts/test-install.sh
echo ""

echo "--- Benchmark Validation ---"
$ZIG build bench-validate
echo ""

echo "=== All release validation checks passed ==="
