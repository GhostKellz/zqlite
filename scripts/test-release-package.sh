#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
CACHE_DIR="$ROOT/.zig-cache"
mkdir -p "$CACHE_DIR"
SCRATCH_DIR="$(mktemp -d "$CACHE_DIR/zqlite-release-package.XXXXXX")"
cleanup() {
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

ARTIFACTS="$SCRATCH_DIR/artifacts"
STAGE="$ARTIFACTS/package"
UNPACKED="$SCRATCH_DIR/unpacked"
mkdir -p "$UNPACKED"

bash "$ROOT/scripts/build-release-artifacts.sh" "$ARTIFACTS"
sha256sum -c "$ARTIFACTS/zqlite-source-package.tar.gz.sha256"
tar -xzf "$ARTIFACTS/zqlite-source-package.tar.gz" -C "$UNPACKED"

test -x "$UNPACKED/package/bin/zqlite"
test -f "$UNPACKED/package/lib/libzqlite.a"
test -f "$UNPACKED/package/lib/libzqlite_c.a"
test -f "$UNPACKED/package/lib/libzqlite_c.so"
test -f "$UNPACKED/package/include/zqlite.h"
test -f "$UNPACKED/package/include/zqlite_c.symbols"
test -s "$ARTIFACTS/SBOM.txt"

nm -D --defined-only "$UNPACKED/package/lib/libzqlite_c.so" \
    | awk '$3 ~ /^zqlite_/ { print $3 }' | sort -u > "$SCRATCH_DIR/library-functions"
grep -Eo 'zqlite_[a-zA-Z0-9_]+[[:space:]]*\(' "$UNPACKED/package/include/zqlite.h" \
    | sed -E 's/[[:space:]]*\($//' | sort -u > "$SCRATCH_DIR/header-functions"
diff -u "$SCRATCH_DIR/header-functions" "$SCRATCH_DIR/library-functions"
sort -u "$UNPACKED/package/include/zqlite_c.symbols" > "$SCRATCH_DIR/manifest-functions"
diff -u "$SCRATCH_DIR/manifest-functions" "$SCRATCH_DIR/header-functions"

cp -R "$ROOT/tests/consumer/zig" "$UNPACKED/consumer"
(cd "$UNPACKED/consumer" && "$ZIG" build)

mkdir -p "$UNPACKED/fetch-consumer"
cp -R "$ROOT/tests/consumer/zig/." "$UNPACKED/fetch-consumer/"
"$ZIG" fetch "$ARTIFACTS/zqlite-source-package.tar.gz" > "$SCRATCH_DIR/fetch-hash"
test -s "$SCRATCH_DIR/fetch-hash"

run_c_consumer() {
    local compiler="$1"
    local output="$2"
    shift 2
    "$ZIG" "$compiler" "$@" "$ROOT/tests/consumer/c/main.c" \
        -I "$UNPACKED/package/include" \
        -L "$UNPACKED/package/lib" -lzqlite_c \
        -Wl,-rpath,"$UNPACKED/package/lib" \
        -o "$output"
    "$output"
}

run_c_static_consumer() {
    local compiler="$1"
    local output="$2"
    shift 2
    "$ZIG" "$compiler" "$@" "$ROOT/tests/consumer/c/main.c" \
        -I "$UNPACKED/package/include" \
        "$UNPACKED/package/lib/libzqlite_c.a" \
        -o "$output"
    "$output"
}

run_c_consumer cc "$SCRATCH_DIR/c99-shared-consumer" -std=c99 -Wall -Wextra -Werror
run_c_static_consumer cc "$SCRATCH_DIR/c99-static-consumer" -std=c99 -Wall -Wextra -Werror

"$ZIG" c++ -x c++ "$ROOT/tests/consumer/c/main.c" \
    -std=c++17 -Wall -Wextra -Werror \
    -I "$UNPACKED/package/include" \
    -L "$UNPACKED/package/lib" -lzqlite_c \
    -Wl,-rpath,"$UNPACKED/package/lib" \
    -o "$SCRATCH_DIR/cxx-shared-consumer"
"$SCRATCH_DIR/cxx-shared-consumer"

"$ZIG" c++ -x c++ "$ROOT/tests/consumer/c/main.c" \
    -std=c++17 -Wall -Wextra -Werror \
    -I "$UNPACKED/package/include" \
    -x none \
    "$UNPACKED/package/lib/libzqlite_c.a" \
    -o "$SCRATCH_DIR/cxx-static-consumer"
"$SCRATCH_DIR/cxx-static-consumer"

echo "Release package Zig, C99, and C++ consumer smoke tests passed"
