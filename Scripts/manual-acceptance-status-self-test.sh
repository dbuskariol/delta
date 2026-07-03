#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

TMP_DIR="$(/usr/bin/mktemp -d -t delta-manual-acceptance-status-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

manual_report="$TMP_DIR/manual.md"
local_report="$TMP_DIR/local.md"
status_report="$TMP_DIR/status.md"

cat >"$manual_report" <<'EOF'
# Delta Manual Acceptance Report

- Generated: 20260702T000000Z UTC
- Tester: Acceptance Status Self Test
- App: /Applications/Delta.app
- Bundle ID: com.delta.backup
- Version: 0.1
- Build: 1
- Git Commit: testsha
- Host macOS: 26.0 (25A000)
- Signing Identity: Developer ID Application: Delta Test
- Local Acceptance Probe: test
- Notes: Self-test fixture

## Results

| ID | Area | Result | Evidence / Notes | Required Evidence |
| --- | --- | --- | --- | --- |
EOF

while IFS=$'\t' read -r id area required_evidence; do
  result="Not run"
  evidence="Manual evidence: TODO"
  if [[ "$id" == "install_identity" ]]; then
    result="Passed"
    evidence="Manual evidence: launched, quit, reinstalled the same signed app identity, and confirmed privacy prompts were stable."
  elif [[ "$id" == "s3_destination" ]]; then
    result="Blocked"
    evidence="Blocked pending provider credentials for the release acceptance bucket."
  fi

  printf '| %s | %s | %s | %s | %s |\n' \
    "$id" \
    "$area" \
    "$result" \
    "$evidence" \
    "$required_evidence" >>"$manual_report"
done < <(manual_acceptance_items)

cat >"$local_report" <<'EOF'
# Delta Local Acceptance Probe

- Generated: 20260702T000000Z UTC
- App: /Applications/Delta.app
- Bundle ID: com.delta.backup
- Version: 0.1
- Build: 1
- Git Commit: testsha
- Host macOS: 26.0 (25A000)

| ID | Area | Local Status | Automated Evidence | Manual Follow-Up |
| --- | --- | --- | --- | --- |
EOF

while IFS=$'\t' read -r id area _required_evidence; do
  local_status="Partial"
  follow_up="Open the installed app and complete the visual or provider-specific manual check."
  if [[ "$id" == "full_disk_access" || "$id" == "developer_id_notarization" ]]; then
    local_status="Manual Required"
    follow_up="Complete this human-only release check."
  fi

  printf '| %s | %s | %s | Automated fixture evidence. | %s |\n' \
    "$id" \
    "$area" \
    "$local_status" \
    "$follow_up" >>"$local_report"
done < <(manual_acceptance_items)

DELTA_LOCAL_ACCEPTANCE_REPORT="$local_report" \
  "$ROOT_DIR/Scripts/manual-acceptance-status.sh" "$manual_report" >"$status_report"

require_contains() {
  local expected="$1"
  if ! /usr/bin/grep -Fq -- "$expected" "$status_report"; then
    printf "Manual acceptance status self-test output was missing: %s\n" "$expected" >&2
    printf "Output:\n" >&2
    /bin/cat "$status_report" >&2
    exit 1
  fi
}

require_contains "# Delta Manual Acceptance Status"
require_contains "- Manual rows passed: 1"
require_contains "- Manual rows blocked: 1"
require_contains "- Manual rows not run: 20"
require_contains "- Local automated partial evidence: 20"
require_contains "- Local human-only rows: 2"
require_contains "Use local automated evidence as support, then complete:"
require_contains "Complete the human-only check:"
require_contains "Resolve the recorded blocker, then rerun this row."
require_contains "External production verification still requires"

printf "Manual acceptance status self-test passed.\n"
