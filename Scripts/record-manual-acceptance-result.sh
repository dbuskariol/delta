#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  Scripts/record-manual-acceptance-result.sh <report> <id> <result> <evidence>

Result must be exactly one of:
  Passed
  Failed
  Blocked
  Not run

Examples:
  Scripts/record-manual-acceptance-result.sh dist/manual-acceptance/latest.md settings_surface Passed "Manual evidence: opened Settings in /Applications/Delta.app 0.2.0 (2), confirmed native General/Permissions/Defaults/Updates/Advanced cards, aligned controls, access actions, update controls, defaults, and diagnostics."
  Scripts/record-manual-acceptance-result.sh dist/manual-acceptance/latest.md s3_destination Blocked "Blocked pending dedicated S3-compatible acceptance bucket credentials."
EOF
}

if [[ "$#" -ne 4 ]]; then
  usage
  exit 64
fi

REPORT="$1"
ROW_ID="$2"
NEW_RESULT="$3"
NEW_EVIDENCE="$4"

if [[ ! -f "$REPORT" ]]; then
  printf "Manual acceptance report was not found at %s\n" "$REPORT" >&2
  exit 1
fi

resolve_report_path() {
  local path="$1"
  if [[ -L "$path" ]]; then
    local target
    target="$(/usr/bin/readlink "$path")"
    if [[ "$target" == /* ]]; then
      printf "%s" "$target"
    else
      printf "%s/%s" "$(cd "$(dirname "$path")/$(dirname "$target")" && pwd -P)" "$(basename "$target")"
    fi
  else
    printf "%s/%s" "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
  fi
}

REPORT_PATH="$(resolve_report_path "$REPORT")"

markdown_cell() {
  printf "%s" "$1" \
    | /usr/bin/tr '\r\n\t' '   ' \
    | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //g' -e 's/ $//g'
}

table_value_for_id() {
  local wanted_id="$1"
  local column="$2"

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
  ' "$REPORT_PATH"
}

canonical_area_for_id() {
  local wanted_id="$1"
  manual_acceptance_items | /usr/bin/awk -F'\t' -v wanted_id="$wanted_id" '$1 == wanted_id { print $2; exit }'
}

validate_result() {
  case "$1" in
    Passed|Failed|Blocked|Not\ run)
      return 0
      ;;
    *)
      printf "Invalid result '%s'. Use exactly one of Passed, Failed, Blocked, or Not run.\n" "$1" >&2
      return 1
      ;;
  esac
}

validate_evidence() {
  local id="$1"
  local result="$2"
  local evidence="$3"
  local evidence_lc

  evidence_lc="$(printf "%s" "$evidence" | /usr/bin/tr '[:upper:]' '[:lower:]')"

  case "$result" in
    Passed)
      if [[ "${#evidence}" -lt 40 ]]; then
        printf "Passed evidence is too thin for %s. Record what was checked, where, and what proved it.\n" "$id" >&2
        return 1
      fi
      if [[ "$evidence" == *"Manual evidence: TODO"* || "$evidence" == *"TODO"* ]]; then
        printf "Passed evidence for %s still contains TODO text.\n" "$id" >&2
        return 1
      fi
      if [[ "$evidence" == *"Local probe:"* || "$evidence" == *"Follow-up still required:"* ]]; then
        printf "Passed evidence for %s must replace generated local-probe text with real manual evidence.\n" "$id" >&2
        return 1
      fi
      if [[ "$evidence_lc" == "ok" || "$evidence_lc" == "pass" || "$evidence_lc" == "passed" || "$evidence_lc" == "done" || "$evidence_lc" == "yes" ]]; then
        printf "Passed evidence for %s is not descriptive enough.\n" "$id" >&2
        return 1
      fi
      if [[ "$evidence_lc" == *"tbd"* || "$evidence_lc" == *"unknown"* || "$evidence_lc" == *"not applicable"* || "$evidence_lc" == *"n/a"* ]]; then
        printf "Passed evidence for %s contains non-evidence wording.\n" "$id" >&2
        return 1
      fi
      ;;
    Failed|Blocked)
      if [[ "${#evidence}" -lt 20 ]]; then
        printf "%s evidence is too thin for %s. Record the concrete failure or blocker.\n" "$result" "$id" >&2
        return 1
      fi
      if [[ "$evidence" == *"TODO"* || "$evidence_lc" == *"tbd"* || "$evidence_lc" == *"unknown"* ]]; then
        printf "%s evidence for %s must be concrete, not TODO/TBD/unknown.\n" "$result" "$id" >&2
        return 1
      fi
      ;;
    Not\ run)
      ;;
  esac
}

canonical_area="$(canonical_area_for_id "$ROW_ID")"
if [[ -z "$canonical_area" ]]; then
  printf "Unknown manual acceptance row id: %s\n" "$ROW_ID" >&2
  printf "Known IDs:\n" >&2
  manual_acceptance_items | /usr/bin/awk -F'\t' '{ print "  " $1 }' >&2
  exit 1
fi

validate_result "$NEW_RESULT"
if [[ "$NEW_RESULT" == "Not run" ]]; then
  NEW_EVIDENCE="${NEW_EVIDENCE:-Manual evidence: TODO}"
else
  validate_evidence "$ROW_ID" "$NEW_RESULT" "$NEW_EVIDENCE"
fi

if ! /usr/bin/grep -q '^## Results$' "$REPORT_PATH"; then
  printf "Manual acceptance report is missing the Results section: %s\n" "$REPORT_PATH" >&2
  exit 1
fi

TMP_OUTPUT="$(/usr/bin/mktemp -t delta-manual-acceptance-record.XXXXXX)"
trap 'rm -f "$TMP_OUTPUT"' EXIT

/usr/bin/awk '
  /^## Results$/ {
    print
    exit
  }
  { print }
' "$REPORT_PATH" >"$TMP_OUTPUT"

cat >>"$TMP_OUTPUT" <<'EOF'

| ID | Area | Result | Evidence / Notes | Required Evidence |
| --- | --- | --- | --- | --- |
EOF

while IFS=$'\t' read -r id area required_evidence; do
  result="$(table_value_for_id "$id" 4)"
  evidence="$(table_value_for_id "$id" 5)"

  if [[ -z "$result" ]]; then
    result="Not run"
  fi
  validate_result "$result"
  if [[ -z "$evidence" ]]; then
    evidence="Manual evidence: TODO"
  fi

  if [[ "$id" == "$ROW_ID" ]]; then
    result="$NEW_RESULT"
    evidence="$NEW_EVIDENCE"
  fi

  printf '| %s | %s | %s | %s | %s |\n' \
    "$(markdown_cell "$id")" \
    "$(markdown_cell "$area")" \
    "$(markdown_cell "$result")" \
    "$(markdown_cell "$evidence")" \
    "$(markdown_cell "$required_evidence")" >>"$TMP_OUTPUT"
done < <(manual_acceptance_items)

cat >>"$TMP_OUTPUT" <<'EOF'

## Release Rule

`Scripts/verify-manual-acceptance.sh` passes only when every required row is present, every Result is `Passed`, and every Evidence / Notes cell has the generated TODO/local-probe follow-up text replaced with real manual evidence.
EOF

/bin/mv "$TMP_OUTPUT" "$REPORT_PATH"
trap - EXIT

printf "Updated %s: %s -> %s\n" "$REPORT_PATH" "$ROW_ID" "$NEW_RESULT"
"$ROOT_DIR/Scripts/manual-acceptance-status.sh" "$REPORT_PATH"

manual_not_ready=0
while IFS=$'\t' read -r id _area _required_evidence; do
  result="$(table_value_for_id "$id" 4)"
  if [[ "$result" != "Passed" ]]; then
    manual_not_ready=1
    break
  fi
done < <(manual_acceptance_items)

if [[ "$manual_not_ready" -eq 0 ]]; then
  "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$REPORT_PATH"
else
  printf "\nManual acceptance is updated, but final verification is not expected to pass until every row is Passed.\n"
fi
