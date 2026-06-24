#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source-dir> <suite-name>" >&2
    echo "example: $0 /path/to/nist/kats/ml-kem-768 ml-kem-768" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$1"
SUITE="$2"
DEST="$ROOT/tests/standalone/fixtures/pqc/official/$SUITE"

case "$SUITE" in
    ml-kem-768|ml-dsa-65) ;;
    *)
        echo "unsupported suite: $SUITE" >&2
        exit 2
        ;;
esac

if [[ ! -d "$SRC_DIR" ]]; then
    echo "source directory does not exist: $SRC_DIR" >&2
    exit 2
fi

mkdir -p "$DEST"
cp "$SRC_DIR"/*.kat "$DEST"/

{
    echo "# PQC Official KAT Provenance"
    echo
    echo "- suite: $SUITE"
    echo "- imported_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- source_dir: $SRC_DIR"
    echo "- importer: scripts/import-pqc-kats.sh"
    echo
    echo "Validate with:"
    echo
    echo '```bash'
    echo "zig build test-pqc --summary all"
    echo '```'
} > "$DEST/PROVENANCE.md"

find "$DEST" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort > "$DEST/MANIFEST.txt"
echo "Imported $SUITE KAT files into $DEST"
