#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/.scratch"
OUTPUT_DIR="$ROOT/zig-out/performance"
BENCH="$SCRATCH/sqlite-comparison"

cleanup() {
    rm -f "$BENCH" "$SCRATCH/perf-zqlite.db" "$SCRATCH/perf-zqlite.db-lock" \
        "$SCRATCH/perf-zqlite.db-writer" "$SCRATCH/perf-zqlite.db-wal" \
        "$SCRATCH/perf-sqlite.db" \
        "$SCRATCH/perf-sqlite.db-shm" "$SCRATCH/perf-sqlite.db-wal"
}
trap cleanup EXIT INT TERM HUP

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required" >&2; exit 1; }
mkdir -p "$SCRATCH" "$OUTPUT_DIR"
cleanup
zig build -Dffi=true -Doptimize=ReleaseSafe
cc -O2 -std=c99 -I"$ROOT/include" "$ROOT/tests/bench/sqlite_comparison.c" \
    -L"$ROOT/zig-out/lib" -Wl,-rpath,"$ROOT/zig-out/lib" -lzqlite_c -lsqlite3 -o "$BENCH"
(
    cd "$ROOT"
    "$BENCH" ".scratch/perf-zqlite.db" ".scratch/perf-sqlite.db"
) | tee "$OUTPUT_DIR/sqlite-comparison.json"
