#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for artifact in root :memory: :memory:-wal :memory:.wal test.wal; do
    if [[ -e "$artifact" ]] && git ls-files --error-unmatch -- "$artifact" >/dev/null 2>&1; then
        echo "generated root-level artifact is tracked: $artifact" >&2
        exit 1
    fi
done

if git diff --check; then
    echo "Repository hygiene checks passed"
fi
