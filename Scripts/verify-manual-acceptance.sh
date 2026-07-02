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
  "Generated"
  "Tester"
  "App"
  "Bundle ID"
  "Version"
  "Build"
  "Git Commit"
  "Host macOS"
  "Signing Identity"
  "Local Acceptance Probe"
)

for key in "${metadata_required[@]}"; do
  value="$(/usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$REPORT")"
  if [[ -z "$value" || "$value" == "Unknown" || "$value" == "Not found" || "$value" == *"TODO"* || "$value" == *"TBD"* ]]; then
    printf "Manual acceptance report metadata is missing or unknown: %s\n" "$key" >&2
    exit 1
  fi
done

expected_commit="${DELTA_MANUAL_ACCEPTANCE_EXPECTED_COMMIT:-$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)}"
report_commit="$(/usr/bin/awk -F': ' '$1 == "- Git Commit" { print $2; exit }' "$REPORT")"
if [[ -n "$expected_commit" && "$report_commit" != "$expected_commit" ]]; then
  printf "Manual acceptance report is for git commit %s, expected %s.\n" "$report_commit" "$expected_commit" >&2
  exit 1
fi

row_count_for_id() {
  local wanted_id="$1"
  /usr/bin/awk -F'|' -v wanted_id="$wanted_id" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^\|/ {
      id = trim($2)
      if (id == wanted_id) {
        count += 1
      }
    }
    END {
      print count + 0
    }
  ' "$REPORT"
}

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

required_evidence_for_id() {
  local wanted_id="$1"
  /usr/bin/awk -F'|' -v wanted_id="$wanted_id" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^\|/ {
      id = trim($2)
      required_evidence = trim($6)
      if (id == wanted_id) {
        print required_evidence
        exit
      }
    }
  ' "$REPORT"
}

validate_passed_evidence() {
  local id="$1"
  local area="$2"
  local evidence="$3"
  local evidence_lc

  if [[ -z "$evidence" ]]; then
    printf "Manual acceptance passed row lacks evidence: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  evidence_lc="$(printf "%s" "$evidence" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  if [[ "${#evidence}" -lt 40 ]]; then
    printf "Manual acceptance passed row evidence is too thin: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == *"Manual evidence: TODO"* || "$evidence" == *"TODO"* ]]; then
    printf "Manual acceptance passed row still has TODO evidence: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence" == *"Local probe:"* ]]; then
    printf "Manual acceptance passed row still contains generated local-probe evidence: %s (%s)\n" "$id" "$area" >&2
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
  if [[ "$evidence_lc" == "ok" || "$evidence_lc" == "pass" || "$evidence_lc" == "passed" || "$evidence_lc" == "done" || "$evidence_lc" == "yes" ]]; then
    printf "Manual acceptance passed row evidence is not descriptive: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  if [[ "$evidence_lc" == *"tbd"* || "$evidence_lc" == *"unknown"* || "$evidence_lc" == *"not applicable"* || "$evidence_lc" == *"n/a"* ]]; then
    printf "Manual acceptance passed row contains non-evidence wording: %s (%s)\n" "$id" "$area" >&2
    return 1
  fi
  return 0
}

while IFS=$'\t' read -r id area _required_evidence; do
  row_count="$(row_count_for_id "$id")"
  if [[ "$row_count" -gt 1 ]]; then
    printf "Manual acceptance report has duplicate row: %s (%s)\n" "$id" "$area" >&2
    failed_count=$((failed_count + 1))
    continue
  fi

  result="$(result_for_id "$id")"
  evidence="$(evidence_for_id "$id")"
  required_evidence="$(required_evidence_for_id "$id")"
  if [[ -z "$result" ]]; then
    printf "Manual acceptance report is missing required row: %s (%s)\n" "$id" "$area" >&2
    missing_count=$((missing_count + 1))
    continue
  fi
  if [[ "$required_evidence" != "$_required_evidence" ]]; then
    printf "Manual acceptance report has stale required evidence for: %s (%s)\n" "$id" "$area" >&2
    failed_count=$((failed_count + 1))
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
