#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  printf "GitHub Actions CI workflow is missing at %s\n" "$WORKFLOW" >&2
  exit 1
fi

if ! /usr/bin/ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"; then
  printf "GitHub Actions CI workflow YAML could not be parsed: %s\n" "$WORKFLOW" >&2
  exit 1
fi

for required in \
  "runs-on: macos-26" \
  "permissions:" \
  "contents: read" \
  "concurrency:" \
  "Scripts/verify-ci.sh"
do
  if ! /usr/bin/grep -Fq "$required" "$WORKFLOW"; then
    printf "GitHub Actions CI workflow is missing required entry: %s\n" "$required" >&2
    exit 1
  fi
done

/bin/bash -n "$ROOT_DIR/Scripts/verify-ci.sh"

printf "CI workflow verified.\n"
