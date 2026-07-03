#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

REPORT="${1:-${DELTA_MANUAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/manual-acceptance/latest.md}}"
LOCAL_ACCEPTANCE_REPORT="${DELTA_LOCAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/local-acceptance/latest.md}"

markdown_cell() {
  printf "%s" "$1" \
    | /usr/bin/tr '\r\n\t' '   ' \
    | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //g' -e 's/ $//g'
}

table_value_for_id() {
  local file="$1"
  local wanted_id="$2"
  local column="$3"

  if [[ ! -f "$file" ]]; then
    return
  fi

  /usr/bin/awk -F'|' -v wanted_id="$wanted_id" -v column="$column" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    /^\|/ {
      id = trim($2)
      if (id == wanted_id) {
        print trim($(column))
        exit
      }
    }
  ' "$file"
}

metadata_value() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return
  fi

  /usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$file"
}

manual_result_for_id() {
  table_value_for_id "$REPORT" "$1" 4
}

manual_evidence_for_id() {
  table_value_for_id "$REPORT" "$1" 5
}

local_status_for_id() {
  table_value_for_id "$LOCAL_ACCEPTANCE_REPORT" "$1" 4
}

local_followup_for_id() {
  table_value_for_id "$LOCAL_ACCEPTANCE_REPORT" "$1" 6
}

next_action_for_row() {
  local result="$1"
  local evidence="$2"
  local local_status="$3"
  local local_followup="$4"
  local required_evidence="$5"

  case "$result" in
    Passed)
      printf "Keep this evidence current for the release commit."
      ;;
    Failed)
      if [[ -n "$evidence" ]]; then
        printf "Fix the failed manual check, then rerun this row. Current evidence: %s" "$evidence"
      else
        printf "Fix the failed manual check, then rerun this row with descriptive evidence."
      fi
      ;;
    Blocked)
      if [[ -n "$evidence" ]]; then
        printf "Resolve the recorded blocker, then rerun this row. Blocker: %s" "$evidence"
      else
        printf "Resolve the blocker, then rerun this row with descriptive evidence."
      fi
      ;;
    Not\ run|"")
      case "$local_status" in
        Partial)
          if [[ -n "$local_followup" ]]; then
            printf "Use local automated evidence as support, then complete: %s" "$local_followup"
          else
            printf "Use local automated evidence as support, then complete the required manual evidence."
          fi
          ;;
        Manual\ Required)
          printf "Complete the human-only check: %s" "$required_evidence"
          ;;
        Failed)
          printf "Fix failing automated local evidence before manual sign-off."
          ;;
        Passed)
          printf "Confirm the installed UI/provider behavior and replace generated notes with manual evidence."
          ;;
        *)
          printf "Run Scripts/run-local-acceptance-probe.sh for support evidence, then complete: %s" "$required_evidence"
          ;;
      esac
      ;;
    *)
      printf "Use one of Passed, Failed, Blocked, or Not run, then provide descriptive evidence."
      ;;
  esac
}

manual_passed=0
manual_failed=0
manual_blocked=0
manual_not_run=0
manual_invalid=0
local_partial=0
local_manual_required=0
local_failed=0
local_passed=0
local_missing=0

while IFS=$'\t' read -r id _area _required_evidence; do
  result="$(manual_result_for_id "$id")"
  local_status="$(local_status_for_id "$id")"

  case "$result" in
    Passed) manual_passed=$((manual_passed + 1)) ;;
    Failed) manual_failed=$((manual_failed + 1)) ;;
    Blocked) manual_blocked=$((manual_blocked + 1)) ;;
    Not\ run|"") manual_not_run=$((manual_not_run + 1)) ;;
    *) manual_invalid=$((manual_invalid + 1)) ;;
  esac

  case "$local_status" in
    Partial) local_partial=$((local_partial + 1)) ;;
    Manual\ Required) local_manual_required=$((local_manual_required + 1)) ;;
    Failed) local_failed=$((local_failed + 1)) ;;
    Passed) local_passed=$((local_passed + 1)) ;;
    *) local_missing=$((local_missing + 1)) ;;
  esac
done < <(manual_acceptance_items)

report_commit="$(metadata_value "$REPORT" "Git Commit")"
local_commit="$(metadata_value "$LOCAL_ACCEPTANCE_REPORT" "Git Commit")"
current_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"

cat <<EOF
# Delta Manual Acceptance Status

- Manual report: $([[ -f "$REPORT" ]] && printf "%s" "$REPORT" || printf "Missing: %s" "$REPORT")
- Local acceptance probe: $([[ -f "$LOCAL_ACCEPTANCE_REPORT" ]] && printf "%s" "$LOCAL_ACCEPTANCE_REPORT" || printf "Missing: %s" "$LOCAL_ACCEPTANCE_REPORT")
- Current git commit: $current_commit
- Manual report commit: ${report_commit:-Unknown}
- Local probe commit: ${local_commit:-Unknown}

## Summary

- Manual rows passed: $manual_passed
- Manual rows not run: $manual_not_run
- Manual rows failed: $manual_failed
- Manual rows blocked: $manual_blocked
- Manual rows invalid: $manual_invalid
- Local automated partial evidence: $local_partial
- Local human-only rows: $local_manual_required
- Local automated failures: $local_failed
- Local automated passed rows: $local_passed
- Local rows without probe evidence: $local_missing

## Remaining Evidence

| ID | Area | Manual Result | Local Probe | Next Action |
| --- | --- | --- | --- | --- |
EOF

while IFS=$'\t' read -r id area required_evidence; do
  result="$(manual_result_for_id "$id")"
  evidence="$(manual_evidence_for_id "$id")"
  local_status="$(local_status_for_id "$id")"
  local_followup="$(local_followup_for_id "$id")"
  next_action="$(next_action_for_row "$result" "$evidence" "$local_status" "$local_followup" "$required_evidence")"

  printf '| %s | %s | %s | %s | %s |\n' \
    "$(markdown_cell "$id")" \
    "$(markdown_cell "$area")" \
    "$(markdown_cell "${result:-Not run}")" \
    "$(markdown_cell "${local_status:-Missing}")" \
    "$(markdown_cell "$next_action")"
done < <(manual_acceptance_items)

cat <<'EOF'

## Release Rule

This status report is informational. External production verification still requires `Scripts/verify-manual-acceptance.sh` to pass against the canonical manual report for the current commit.
EOF
