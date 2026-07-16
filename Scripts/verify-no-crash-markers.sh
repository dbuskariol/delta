#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

scan_with_system_grep() {
  local source status found=1

  while IFS= read -r -d '' source; do
    status=0
    /usr/bin/grep -nE "fatalError|preconditionFailure|assertionFailure\\(" "$source" || status=$?
    case "$status" in
      0) found=0 ;;
      1) ;;
      *) return "$status" ;;
    esac
  done < <(/usr/bin/find Sources -type f -name '*.swift' -print0)

  return "$found"
}

SCAN_STATUS=0
if [[ "${DELTA_FORCE_SYSTEM_GREP_CRASH_SCAN:-0}" != "1" ]] && command -v rg >/dev/null 2>&1; then
  rg -n "fatalError|preconditionFailure|assertionFailure\\(" Sources || SCAN_STATUS=$?
else
  scan_with_system_grep || SCAN_STATUS=$?
fi

if [[ "$SCAN_STATUS" -eq 0 ]]; then
  printf "Production sources contain crash-only markers. Replace them with recoverable error handling before release.\n" >&2
  exit 1
fi
if [[ "$SCAN_STATUS" -ne 1 ]]; then
  printf "Crash-only marker scan failed with status %s.\n" "$SCAN_STATUS" >&2
  exit "$SCAN_STATUS"
fi

printf "Crash-only marker scan passed.\n"
