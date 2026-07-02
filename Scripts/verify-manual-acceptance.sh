#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

REPORT="${1:-${DELTA_MANUAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/manual-acceptance/latest.md}}"

if [[ ! -f "$REPORT" ]]; then
  printf "Manual acceptance report was not found at %s\n" "$REPORT" >&2
  printf "Create one with Scripts/create-manual-acceptance-report.sh, then fill in the Result and Evidence / Notes columns.\n" >&2
  exit 1
fi

missing_count=0
failed_count=0
passed_count=0

metadata_required=(
  "Tester"
  "App"
  "Bundle ID"
  "Version"
  "Build"
  "Git Commit"
  "Host macOS"
  "Signing Identity"
)

for key in "${metadata_required[@]}"; do
  value="$(/usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$REPORT")"
  if [[ -z "$value" || "$value" == "Unknown" ]]; then
    printf "Manual acceptance report metadata is missing or unknown: %s\n" "$key" >&2
    exit 1
  fi
done

result_for_id() {
  local wanted_id="$1"
  /usr/bin/awk -F'|' -v wanted_id="$wanted_id" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^\|/ {
      id = trim($2)
      result = trim($4)
      if (id == wanted_id) {
        print result
        exit
      }
    }
  ' "$REPORT"
}

evidence_for_id() {
  local wanted_id="$1"
  /usr/bin/awk -F'|' -v wanted_id="$wanted_id" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^\|/ {
      id = trim($2)
      evidence = trim($5)
      if (id == wanted_id) {
        print evidence
        exit
      }
    }
  ' "$REPORT"
}

validate_passed_evidence() {
  local id="$1"
  local area="$2"
  local evidence="$3"

  if [[ -z "$evidence" ]]; then
    printf "Manual acceptance passed row lacks evidence: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == *"Manual evidence: TODO"* || "$evidence" == *"TODO"* ]]; then
    printf "Manual acceptance passed row still has TODO evidence: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == Local\ probe:* ]]; then
    printf "Manual acceptance passed row still starts with generated local-probe evidence: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == *"Follow-up still required:"* ]]; then
    printf "Manual acceptance passed row still contains generated follow-up text: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == *"Not run"* ]]; then
    printf "Manual acceptance passed row still says not run: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  return 0
}

while IFS=$'\t' read -r id area _required_evidence; do
  result="$(result_for_id "$id")"
  evidence="$(evidence_for_id "$id")"
  if [[ -z "$result" ]]; then
    printf "Manual acceptance report is missing required row: %s (%s)\n" "$id" "$area" >&2
    missing_count=$((missing_count + 1))
    continue
  fi

  case "$result" in
    Passed)
      if validate_passed_evidence "$id" "$area" "$evidence"; then
        passed_count=$((passed_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
      ;;
    Failed|Blocked|Not\ run)
      printf "Manual acceptance is not passed: %s (%s) is %s\n" "$id" "$area" "$result" >&2
      failed_count=$((failed_count + 1))
      ;;
    *)
      printf "Manual acceptance row has invalid Result: %s (%s) is %s\n" "$id" "$area" "$result" >&2
      failed_count=$((failed_count + 1))
      ;;
  esac
done < <(manual_acceptance_items)

if [[ "$missing_count" -ne 0 || "$failed_count" -ne 0 ]]; then
  printf "Manual acceptance failed: %d passed, %d missing, %d not passed.\n" "$passed_count" "$missing_count" "$failed_count" >&2
  exit 1
fi

printf "Manual acceptance passed: %d required checks passed in %s\n" "$passed_count" "$REPORT"
