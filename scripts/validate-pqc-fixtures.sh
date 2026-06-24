#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/standalone/fixtures/pqc"

fail() {
    echo "pqc fixture validation failed: $*" >&2
    exit 1
}

require_field() {
    local file="$1"
    local field="$2"
    grep -Eq "^[[:space:]]*$field[[:space:]]*=" "$file" || fail "$file missing field: $field"
}

validate_kem() {
    local file="$1"
    require_field "$file" key_seed
    require_field "$file" encaps_seed
    if [[ "$file" == */generated/* || "$file" == */official/* ]]; then
        require_field "$file" suite
        require_field "$file" source
        require_field "$file" classification
        require_field "$file" expected_public_key
        require_field "$file" expected_secret_key
        require_field "$file" expected_ciphertext
        require_field "$file" expected_shared_secret
    fi
}

validate_sign() {
    local file="$1"
    require_field "$file" seed
    require_field "$file" message
    if [[ "$file" == */generated/* || "$file" == */official/* ]]; then
        require_field "$file" suite
        require_field "$file" source
        require_field "$file" classification
        require_field "$file" expected_public_key
        require_field "$file" expected_secret_key
        require_field "$file" expected_signature
    fi
}

while IFS= read -r -d '' file; do
    case "$file" in
        */ml-kem-768/*.kat) validate_kem "$file" ;;
        */ml-dsa-65/*.kat) validate_sign "$file" ;;
        *) fail "$file is not under a supported PQC suite directory" ;;
    esac

    if [[ "$file" == */official/* ]]; then
        require_field "$file" provenance
        grep -Eq '^[[:space:]]*classification[[:space:]]*=[[:space:]]*official' "$file" ||
            fail "$file official fixture must set classification = official"
    fi

    if [[ "$file" == */generated/* ]]; then
        grep -Eq '^[[:space:]]*classification[[:space:]]*=[[:space:]]*generated' "$file" ||
            fail "$file generated fixture must set classification = generated"
    fi
done < <(find "$FIXTURES" -type f -name '*.kat' -print0)

echo "PQC fixture manifests validated"
