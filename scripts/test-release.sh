#!/bin/bash
# ZQLite Release Validation Script
# Runs full test coverage beyond CI defaults

set -e

echo "=== ZQLite Release Validation ==="
echo ""

echo "--- Format Check ---"
zig fmt --check src/
zig fmt --check examples/
zig fmt --check tests/
echo "OK"
echo ""

echo "--- Build ---"
zig build
echo "OK"
echo ""

echo "--- Core Tests ---"
zig build test --summary all
echo ""

echo "--- Quick Tests ---"
zig build test-quick
echo ""

echo "--- Security Tests ---"
zig build test-security
echo ""

echo "--- Comprehensive Tests ---"
zig build test-comprehensive
echo ""

echo "--- Storage Tests ---"
zig build test-storage
echo ""

echo "--- Advanced Tests ---"
zig build test-advanced
echo ""

echo "--- C API Tests ---"
zig build test-c-api
echo ""

echo "--- Benchmark Validation ---"
zig build bench-validate
echo ""

echo "=== All release validation checks passed ==="
