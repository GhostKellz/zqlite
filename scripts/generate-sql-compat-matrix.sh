#!/usr/bin/env bash
set -euo pipefail

manifest="${1:-tests/sql_compatibility.tsv}"

printf '# SQL Compatibility Matrix\n\n'
printf 'Generated from `%s`.\n\n' "$manifest"
printf '| Feature | Status | Scope | Tests | Notes |\n'
printf '| --- | --- | --- | --- | --- |\n'

tail -n +2 "$manifest" | while IFS=$'\t' read -r feature status scope tests notes; do
  tests="${tests//;/<br>}"
  printf '| %s | %s | %s | %s | %s |\n' "$feature" "$status" "$scope" "$tests" "$notes"
done
