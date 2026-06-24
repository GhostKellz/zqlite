#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "ZQLite stable-core coverage workload"
echo "===================================="
echo
echo "collector: ${ZQLITE_COVERAGE_COLLECTOR:-workload}"
if command -v kcov >/dev/null 2>&1; then
  echo "kcov: available"
else
  echo "kcov: not found; recording deterministic workload evidence only"
fi
if command -v llvm-cov >/dev/null 2>&1; then
  echo "llvm-cov: available"
else
  echo "llvm-cov: not found"
fi
echo
echo "Running stable tests used for coverage collection:"
zig build test --summary all
zig build test-sql-conformance --summary all
zig build test-storage --summary all
zig build test-c-api --summary all
zig build test-storage-stress --summary all
echo
echo "Stable coverage scope:"
printf '  %s\n' \
  "src/db/" \
  "src/parser/" \
  "src/executor/" \
  "src/ffi/" \
  "src/sqlite_compat/"
echo
echo "Attach the self-hosted runner's selected coverage collector around this script,"
echo "or install kcov/llvm-cov and archive their generated reports next to this workload artifact."
echo "Experimental crypto/transport/distributed modules are excluded from v1.7.0 stable-core coverage gates."
