#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/zig-out/release}"
ARCHIVE="$OUT_DIR/zqlite-source-package.tar.gz"
CHECKSUM="$OUT_DIR/zqlite-source-package.tar.gz.sha256"
CHECKSUMS="$OUT_DIR/SHA256SUMS"
SBOM="$OUT_DIR/SBOM.txt"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "missing release artifact: $1" >&2
        exit 1
    fi
}

require_file "$ARCHIVE"
require_file "$CHECKSUM"
require_file "$CHECKSUMS"
require_file "$SBOM"

(
    cd "$OUT_DIR"
    sha256sum -c "$(basename "$CHECKSUM")"
    sha256sum -c "$(basename "$CHECKSUMS")"
)

archive_list="$(tar -tzf "$ARCHIVE")"
grep -qx 'package/build.zig' <<<"$archive_list"
grep -qx 'package/build.zig.zon' <<<"$archive_list"
grep -qx 'package/README.md' <<<"$archive_list"
grep -qx 'package/CHANGELOG.md' <<<"$archive_list"
grep -qx 'package/src/zqlite.zig' <<<"$archive_list"
grep -qx 'package/include/zqlite.h' <<<"$archive_list"

grep -qx 'build.zig' "$SBOM"
grep -qx 'build.zig.zon' "$SBOM"
grep -qx 'src/zqlite.zig' "$SBOM"
grep -qx 'include/zqlite.h' "$SBOM"

if [[ -f "$ARCHIVE.minisig" ]]; then
    if command -v minisign >/dev/null 2>&1; then
        if [[ -n "${ZQLITE_MINISIGN_PUBKEY:-}" ]]; then
            minisign -Vm "$ARCHIVE" -P "$ZQLITE_MINISIGN_PUBKEY"
        else
            echo "minisign signature present; set ZQLITE_MINISIGN_PUBKEY to verify it"
        fi
    else
        echo "minisign signature present; minisign not installed"
    fi
fi

if [[ -f "$ARCHIVE.asc" ]]; then
    if command -v gpg >/dev/null 2>&1; then
        gpg --batch --verify "$ARCHIVE.asc" "$ARCHIVE"
    else
        echo "GPG signature present; gpg not installed"
    fi
fi

echo "Release artifacts verified in $OUT_DIR"
