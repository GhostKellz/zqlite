#!/bin/bash
# ZQLite Zig 0.17.0-dev Compatibility Check
# Validates code against the current Zig API baseline

set -e

ZIG="${ZIG:-zig}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "=== ZQLite Zig 0.17.0-dev Compatibility Check ==="
echo "Zig version: $($ZIG version)"
echo ""

ERRORS=0

# Check for deprecated APIs
echo "Checking for deprecated API usage..."

# Check for deprecated std.array_list.Managed
MANAGED_COUNT=$(grep -r "std\.array_list\.Managed" src/ 2>/dev/null | wc -l || echo 0)
if [ "$MANAGED_COUNT" -gt 0 ]; then
    echo "⚠ Found $MANAGED_COUNT uses of deprecated std.array_list.Managed"
    echo "  Use std.ArrayList(T) with .{} init instead"
fi

# Check for deprecated milliTimestamp
MILLI_COUNT=$(grep -r "std\.time\.milliTimestamp" src/ 2>/dev/null | wc -l || echo 0)
if [ "$MILLI_COUNT" -gt 0 ]; then
    echo "✗ Found $MILLI_COUNT uses of removed std.time.milliTimestamp"
    echo "  Use std.posix.clock_gettime(.REALTIME) instead"
    ERRORS=$((ERRORS + 1))
fi

# Check for deprecated nanoTimestamp
NANO_COUNT=$(grep -r "std\.time\.nanoTimestamp" src/ 2>/dev/null | wc -l || echo 0)
if [ "$NANO_COUNT" -gt 0 ]; then
    echo "✗ Found $NANO_COUNT uses of removed std.time.nanoTimestamp"
    echo "  Use std.time.Instant.now() instead"
    ERRORS=$((ERRORS + 1))
fi

# Check for old std.net API
NET_COUNT=$(grep -r "std\.net\." src/ 2>/dev/null | grep -v "std\.Io\.net" | wc -l || echo 0)
if [ "$NET_COUNT" -gt 0 ]; then
    echo "✗ Found $NET_COUNT uses of old std.net API"
    echo "  Use std.Io.net instead"
    ERRORS=$((ERRORS + 1))
fi

echo ""

if [ "$ERRORS" -gt 0 ]; then
    echo "✗ Compatibility check FAILED with $ERRORS critical issues"
    exit 1
else
    echo "✓ Compatibility check PASSED"
    if [ "$MANAGED_COUNT" -gt 0 ]; then
        echo "  (Some deprecated aliases still in use - consider updating)"
    fi
fi
