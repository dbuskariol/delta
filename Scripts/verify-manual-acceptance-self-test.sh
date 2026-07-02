#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

TMP_DIR="$(/usr/bin/mktemp -d -t delta-manual-acceptance-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_report() {
  local output="$1"
  local result="$2"
  local evidence="$3"

  cat >"$output" <<EOF
# Delta Manual Acceptance Report

- Generated: 20260702T000000Z UTC
- Tester: Acceptance Self Test
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
    printf '| %s | %s | %s | %s | %s |\n' \
      "$id" \
      "$area" \
      "$result" \
      "$evidence" \
      "$required_evidence" >>"$output"
  done < <(manual_acceptance_items)
}

expect_failure() {
  local report="$1"
  local label="$2"
  if "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$report" >/dev/null 2>&1; then
    printf "Expected manual acceptance verification to fail for %s.\n" "$label" >&2
    exit 1
  fi
}

good_report="$TMP_DIR/good.md"
todo_report="$TMP_DIR/todo.md"
probe_report="$TMP_DIR/probe.md"

write_report "$good_report" "Passed" "Manual evidence: observed the required behavior in the installed app and recorded release notes."
"$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$good_report" >/dev/null

write_report "$todo_report" "Passed" "Manual evidence: TODO"
expect_failure "$todo_report" "TODO evidence"

write_report "$probe_report" "Passed" "Local probe: Partial. Automated evidence only. Follow-up still required: perform the manual check."
expect_failure "$probe_report" "generated local-probe evidence"

printf "Manual acceptance verifier self-test passed.\n"
