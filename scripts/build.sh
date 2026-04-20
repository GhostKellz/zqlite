#!/bin/bash
# ZQLite Build Script - Zig 0.17.0-dev
# Builds library with specified profile and options

set -e

ZIG="${ZIG:-zig}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PROFILE="${1:-full}"
OPTIMIZE="${2:-Debug}"

echo "=== ZQLite Build ==="
echo "Profile: $PROFILE"
echo "Optimize: $OPTIMIZE"
echo "Zig version: $($ZIG version)"
echo ""

$ZIG build -Dprofile="$PROFILE" -Doptimize="$OPTIMIZE"

echo ""
echo "Build complete. Output in zig-out/"
ls -la zig-out/lib/ 2>/dev/null || true
ls -la zig-out/bin/ 2>/dev/null || true
