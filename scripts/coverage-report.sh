#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COVERAGE_ROOT="${ZQLITE_COVERAGE_DIR:-$ROOT/zig-out/coverage}"
BUILD_ROOT="$COVERAGE_ROOT/build"
REPORT_ROOT="$COVERAGE_ROOT/report"
RUN_ROOT="$ROOT/.scratch/zqlite-coverage-runs"

if ! command -v kcov >/dev/null 2>&1; then
    echo "kcov is required to generate ZQLite line coverage" >&2
    exit 1
fi

cleanup() {
    rm -rf "$RUN_ROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

rm -rf "$COVERAGE_ROOT" "$RUN_ROOT"
mkdir -p "$COVERAGE_ROOT" "$RUN_ROOT"

bash "$ROOT/scripts/check-zig-version.sh"
zig build coverage-binaries -Dprofile=advanced -Doptimize=Debug --prefix "$BUILD_ROOT" --summary all

include_path="$ROOT/src"
exclude_paths="$ROOT/src/crypto,$ROOT/src/transport,$ROOT/src/distributed,$ROOT/src/cluster,$ROOT/src/wallet"

for binary in "$BUILD_ROOT"/bin/*; do
    name="$(basename "$binary")"
    kcov \
        --include-path="$include_path" \
        --exclude-path="$exclude_paths" \
        "$RUN_ROOT/$name" \
        "$binary"
done

kcov --merge "$REPORT_ROOT" "$RUN_ROOT"/*

cobertura="$REPORT_ROOT/kcov-merged/cobertura.xml"
if [[ ! -s "$cobertura" ]]; then
    echo "kcov did not produce the expected Cobertura report: $cobertura" >&2
    exit 1
fi

line_rate="$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' "$cobertura" | head -n 1)"
branch_rate="$(sed -n 's/.*branch-rate="\([0-9.]*\)".*/\1/p' "$cobertura" | head -n 1)"
lines_valid="$(sed -n 's/.*lines-valid="\([0-9]*\)".*/\1/p' "$cobertura" | head -n 1)"
if [[ -z "$line_rate" || -z "$branch_rate" || -z "$lines_valid" ]]; then
    echo "unable to read coverage rates from $cobertura" >&2
    exit 1
fi
if [[ "$lines_valid" -eq 0 ]]; then
    echo "kcov reported zero valid stable-core lines; refusing to publish an empty coverage baseline" >&2
    exit 1
fi
printf '{"schema_version":1,"lines_valid":%s,"line_rate":%s,"branch_rate":%s}\n' \
    "$lines_valid" "$line_rate" "$branch_rate" > "$REPORT_ROOT/summary.json"

if [[ -n "${ZQLITE_MIN_LINE_COVERAGE:-}" ]]; then
    awk -v actual="$line_rate" -v minimum="$ZQLITE_MIN_LINE_COVERAGE" \
        'BEGIN { if (actual + 0 < minimum + 0) exit 1 }' || {
        echo "line coverage $line_rate is below required $ZQLITE_MIN_LINE_COVERAGE" >&2
        exit 1
    }
fi

echo "Coverage report: $REPORT_ROOT/kcov-merged/index.html"
echo "Cobertura report: $cobertura"
echo "Machine-readable summary: $REPORT_ROOT/summary.json"
