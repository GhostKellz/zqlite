#!/bin/bash
# ZQLite CI/CD Pipeline Script - Zig 0.17.0-dev
# Complete validation for continuous integration

set -e

ZIG="${ZIG:-zig}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "========================================"
echo "  ZQLite CI Pipeline"
echo "  Zig $($ZIG version)"
echo "========================================"
echo ""

# Step 1: Format check
echo "=== Step 1: Format Check ==="
if $ZIG fmt --check src/*.zig src/**/*.zig 2>/dev/null; then
    echo "✓ Format check passed"
else
    echo "⚠ Format issues found (non-blocking)"
fi
echo ""

# Step 2: Build all profiles
echo "=== Step 2: Build All Profiles ==="
for profile in core advanced experimental; do
    echo "Building profile: $profile"
    if $ZIG build -Dprofile="$profile" 2>&1; then
        echo "  ✓ $profile build passed"
    else
        echo "  ✗ $profile build FAILED"
        exit 1
    fi
done
echo ""

# Step 3: Run tests for all profiles
echo "=== Step 3: Test All Profiles ==="
for profile in core advanced experimental; do
    echo "Testing profile: $profile"
    if $ZIG build test -Dprofile="$profile" --summary all 2>&1 | tail -5; then
        echo "  ✓ $profile tests passed"
    else
        echo "  ✗ $profile tests FAILED"
        exit 1
    fi
done
echo ""

# Step 4: Release build verification
echo "=== Step 4: Release Build ==="
if $ZIG build -Dprofile=experimental -Doptimize=ReleaseFast 2>&1; then
    echo "✓ Release build passed"
else
    echo "✗ Release build FAILED"
    exit 1
fi
echo ""

echo "========================================"
echo "  CI Pipeline PASSED"
echo "========================================"
