#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

DOC="${1:-$ROOT_DIR/docs/PRODUCTION_READINESS.md}"

if [[ ! -f "$DOC" ]]; then
  printf "Production-readiness document not found at %s\n" "$DOC" >&2
  exit 1
fi

missing_count=0
while IFS=$'\t' read -r _id area required_evidence; do
  expected_row="| $area | $required_evidence |"
  if ! /usr/bin/grep -Fqx "$expected_row" "$DOC"; then
    printf "Production-readiness manual matrix is missing or stale for: %s\n" "$area" >&2
    printf "Expected row:\n%s\n" "$expected_row" >&2
    missing_count=$((missing_count + 1))
  fi
done < <(manual_acceptance_items)

if [[ "$missing_count" -ne 0 ]]; then
  printf "Manual acceptance matrix consistency failed: %d stale or missing row(s).\n" "$missing_count" >&2
  exit 1
fi

printf "Manual acceptance matrix verified against %s\n" "$DOC"
