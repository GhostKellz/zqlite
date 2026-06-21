#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STAGE="$TMP_DIR/stage/package"
UNPACKED="$TMP_DIR/unpacked"
mkdir -p "$STAGE" "$UNPACKED"

"$ZIG" build --prefix "$STAGE" -Dprofile=advanced -Doptimize=ReleaseSafe

cp "$ROOT/build.zig" "$ROOT/build.zig.zon" "$ROOT/README.md" \
    "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" "$ROOT/SECURITY.md" "$ROOT/install.sh" "$STAGE/"
cp -R "$ROOT/src" "$ROOT/docs" "$ROOT/examples" "$ROOT/tests" "$ROOT/scripts" "$STAGE/"

tar -czf "$TMP_DIR/zqlite-package.tar.gz" -C "$TMP_DIR/stage" package
tar -xzf "$TMP_DIR/zqlite-package.tar.gz" -C "$UNPACKED"

test -x "$UNPACKED/package/bin/zqlite"
test -f "$UNPACKED/package/lib/libzqlite.a"
test -f "$UNPACKED/package/lib/libzqlite_c.a"
test -f "$UNPACKED/package/lib/libzqlite_c.so"
test -f "$UNPACKED/package/include/zqlite.h"

nm -D --defined-only "$UNPACKED/package/lib/libzqlite_c.so" \
    | awk '$3 ~ /^zqlite_/ { print $3 }' | sort -u > "$TMP_DIR/library-functions"
grep -Eo 'zqlite_[a-zA-Z0-9_]+[[:space:]]*\(' "$UNPACKED/package/include/zqlite.h" \
    | sed -E 's/[[:space:]]*\($//' | sort -u > "$TMP_DIR/header-functions"
diff -u "$TMP_DIR/header-functions" "$TMP_DIR/library-functions"

cp -R "$ROOT/tests/consumer/zig" "$UNPACKED/consumer"
(cd "$UNPACKED/consumer" && "$ZIG" build)

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

run_c_consumer cc "$TMP_DIR/c99-shared-consumer" -std=c99 -Wall -Wextra -Werror
run_c_static_consumer cc "$TMP_DIR/c99-static-consumer" -std=c99 -Wall -Wextra -Werror

"$ZIG" c++ -x c++ "$ROOT/tests/consumer/c/main.c" \
    -std=c++17 -Wall -Wextra -Werror \
    -I "$UNPACKED/package/include" \
    -L "$UNPACKED/package/lib" -lzqlite_c \
    -Wl,-rpath,"$UNPACKED/package/lib" \
    -o "$TMP_DIR/cxx-shared-consumer"
"$TMP_DIR/cxx-shared-consumer"

"$ZIG" c++ -x c++ "$ROOT/tests/consumer/c/main.c" \
    -std=c++17 -Wall -Wextra -Werror \
    -I "$UNPACKED/package/include" \
    -x none \
    "$UNPACKED/package/lib/libzqlite_c.a" \
    -o "$TMP_DIR/cxx-static-consumer"
"$TMP_DIR/cxx-static-consumer"

echo "Release package Zig, C99, and C++ consumer smoke tests passed"
