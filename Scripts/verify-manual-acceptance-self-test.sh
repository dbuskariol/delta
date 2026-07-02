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
  if DELTA_MANUAL_ACCEPTANCE_EXPECTED_COMMIT=testsha "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$report" >/dev/null 2>&1; then
    printf "Expected manual acceptance verification to fail for %s.\n" "$label" >&2
    exit 1
  fi
}

good_report="$TMP_DIR/good.md"
todo_report="$TMP_DIR/todo.md"
probe_report="$TMP_DIR/probe.md"
thin_report="$TMP_DIR/thin.md"
stale_commit_report="$TMP_DIR/stale-commit.md"
duplicate_report="$TMP_DIR/duplicate.md"
stale_required_report="$TMP_DIR/stale-required.md"

write_report "$good_report" "Passed" "Manual evidence: observed the required behavior in the installed app and recorded release notes."
DELTA_MANUAL_ACCEPTANCE_EXPECTED_COMMIT=testsha "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$good_report" >/dev/null

write_report "$todo_report" "Passed" "Manual evidence: TODO"
expect_failure "$todo_report" "TODO evidence"

write_report "$probe_report" "Passed" "Manual evidence: observed the required behavior. Local probe: Partial. Follow-up still required: perform the manual check."
expect_failure "$probe_report" "generated local-probe evidence"

write_report "$thin_report" "Passed" "ok"
expect_failure "$thin_report" "thin evidence"

write_report "$stale_commit_report" "Passed" "Manual evidence: observed the required behavior in the installed app and recorded release notes."
if DELTA_MANUAL_ACCEPTANCE_EXPECTED_COMMIT=othersha "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$stale_commit_report" >/dev/null 2>&1; then
  printf "Expected manual acceptance verification to fail for stale commit.\n" >&2
  exit 1
fi

write_report "$duplicate_report" "Passed" "Manual evidence: observed the required behavior in the installed app and recorded release notes."
/usr/bin/awk '{ print } /^\| install_identity / && !duplicated { print; duplicated = 1 }' "$duplicate_report" >"$duplicate_report.tmp"
/bin/mv "$duplicate_report.tmp" "$duplicate_report"
expect_failure "$duplicate_report" "duplicate rows"

write_report "$stale_required_report" "Passed" "Manual evidence: observed the required behavior in the installed app and recorded release notes."
/usr/bin/perl -0pi -e 's#Install /Applications/Delta\.app, launch it, quit, relaunch, and confirm macOS privacy prompts remain stable across rebuilds signed by the same identity\.#Stale acceptance text.#' "$stale_required_report"
expect_failure "$stale_required_report" "stale required evidence"

printf "Manual acceptance verifier self-test passed.\n"
