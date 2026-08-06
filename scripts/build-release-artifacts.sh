#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
OUT_DIR="${1:-$ROOT/zig-out/release}"
if [[ "$OUT_DIR" != /* ]]; then
    OUT_DIR="$ROOT/$OUT_DIR"
fi
PKG_DIR="$OUT_DIR/package"
ARCHIVE="$OUT_DIR/zqlite-source-package.tar.gz"
SBOM="$OUT_DIR/SBOM.txt"
CHECKSUMS="$OUT_DIR/SHA256SUMS"

rm -rf "$OUT_DIR"
mkdir -p "$PKG_DIR"

cd "$ROOT"
"$ZIG" build --prefix "$PKG_DIR" -Dprofile=advanced -Doptimize=ReleaseSafe

cp "$ROOT/build.zig" "$ROOT/build.zig.zon" "$ROOT/README.md" \
    "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" "$ROOT/SECURITY.md" "$ROOT/install.sh" "$PKG_DIR/"
cp -R "$ROOT/src" "$ROOT/docs" "$ROOT/examples" "$ROOT/tests" "$ROOT/scripts" "$PKG_DIR/"

tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
    -czf "$ARCHIVE" -C "$OUT_DIR" package

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
find "$PKG_DIR" -type f -printf '%P\n' | LC_ALL=C sort > "$SBOM"
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$ARCHIVE")" "SBOM.txt" > "$CHECKSUMS"
)

if command -v minisign >/dev/null 2>&1 && [[ -n "${ZQLITE_MINISIGN_KEY:-}" ]]; then
    minisign -Sm "$ARCHIVE" -s "$ZQLITE_MINISIGN_KEY"
fi

if command -v gpg >/dev/null 2>&1 && [[ "${ZQLITE_GPG_SIGN:-0}" == "1" ]]; then
    gpg --batch --yes --armor --detach-sign "$ARCHIVE"
fi

echo "Release artifacts written to $OUT_DIR"
echo "Archive: $ARCHIVE"
echo "Checksum: $ARCHIVE.sha256"
echo "SBOM: $SBOM"
echo "Checksum manifest: $CHECKSUMS"
