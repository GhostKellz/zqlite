#!/bin/bash
# ZQLite Test Runner - Zig 0.17.0-dev
# Runs comprehensive test suite with all profiles

set -e

ZIG="${ZIG:-zig}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "=== ZQLite Test Suite ==="
echo "Zig version: $($ZIG version)"
echo ""

# Run tests for each profile
for profile in core advanced full; do
    echo "--- Testing profile: $profile ---"
    if $ZIG build test -Dprofile="$profile" --summary all 2>&1; then
        echo "✓ Profile $profile: PASSED"
    else
        echo "✗ Profile $profile: FAILED"
        exit 1
    fi
    echo ""
done

echo "=== All Tests Passed ==="
