#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT/.zig-cache"
mkdir -p "$CACHE_DIR"
SCRATCH_DIR="$(mktemp -d "$CACHE_DIR/zqlite-install.XXXXXX")"
cleanup() {
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

ARTIFACTS="$SCRATCH_DIR/artifacts"
INSTALL_BIN="$SCRATCH_DIR/bin"

bash "$ROOT/scripts/build-release-artifacts.sh" "$ARTIFACTS" >/dev/null

ZQLITE_RELEASE_ARCHIVE="$ARTIFACTS/zqlite-source-package.tar.gz" \
INSTALL_DIR="$INSTALL_BIN/release" \
ZQLITE_REF="v-local-test" \
bash "$ROOT/install.sh"

"$INSTALL_BIN/release/zqlite" --version >/dev/null

ZQLITE_SOURCE_INSTALL=1 \
ZQLITE_LOCAL_SOURCE="$ROOT" \
INSTALL_DIR="$INSTALL_BIN/source" \
ZQLITE_REF="local-source-test" \
bash "$ROOT/install.sh"

"$INSTALL_BIN/source/zqlite" --version >/dev/null

echo "Install script release-archive and source paths passed"
