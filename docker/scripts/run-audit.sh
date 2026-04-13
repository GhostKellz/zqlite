#!/bin/sh
set -eu

echo "=== ZQLite Docker Audit ==="
echo

echo "--- Critical path ---"
sh /workspace/zqlite/docker/scripts/test-critical.sh

echo
echo "--- Full validation ---"
sh /workspace/zqlite/docker/scripts/full-validation.sh

echo
echo "--- Valgrind audit ---"
sh /workspace/zqlite/docker/scripts/run-valgrind.sh

echo
echo "=== Docker audit completed ==="
