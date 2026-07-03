#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

TMP_DIR="$(/usr/bin/mktemp -d -t delta-record-manual-acceptance-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

report_target="$TMP_DIR/manual-target.md"
report_link="$TMP_DIR/latest.md"
status_output="$TMP_DIR/status.md"

write_report() {
  local output="$1"

  cat >"$output" <<'EOF'
# Delta Manual Acceptance Report

- Generated: 20260702T000000Z UTC
- Tester: Record Manual Acceptance Self Test
- App: /Applications/Delta.app
- Bundle ID: com.delta.backup
- Version: 0.1
- Build: 1
- Git Commit: testsha
- Host macOS: 26.0 (25A000)
- Signing Identity: Developer ID Application: Delta Test
- Local Acceptance Probe: test
- Notes: Self-test fixture

## Result Values

Use exactly one of these values in the Result column:

- Passed
- Failed
- Blocked
- Not run

## Results

| ID | Area | Result | Evidence / Notes | Required Evidence |
| --- | --- | --- | --- | --- |
EOF

  while IFS=$'\t' read -r id area required_evidence; do
    printf '| %s | %s | Not run | Manual evidence: TODO | %s |\n' \
      "$id" \
      "$area" \
      "$required_evidence" >>"$output"
  done < <(manual_acceptance_items)

  cat >>"$output" <<'EOF'

## Release Rule

`Scripts/verify-manual-acceptance.sh` passes only when every required row is present, every Result is `Passed`, and every Evidence / Notes cell has the generated TODO/local-probe follow-up text replaced with real manual evidence.
EOF
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "Expected record-manual-acceptance-result to fail for %s.\n" "$label" >&2
    exit 1
  fi
}

write_report "$report_target"
/bin/ln -s "$(basename "$report_target")" "$report_link"

"$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  install_identity \
  Passed \
  "Manual evidence: launched /Applications/Delta.app, quit, reinstalled the same signed app identity, relaunched, and confirmed privacy prompts stayed stable." >"$status_output"

if [[ ! -L "$report_link" ]]; then
  printf "Recorder replaced the latest.md symlink instead of editing its target.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq '| install_identity | Install identity and privacy stability | Passed | Manual evidence: launched /Applications/Delta.app, quit, reinstalled the same signed app identity, relaunched, and confirmed privacy prompts stayed stable.' "$report_target"; then
  printf "Recorder did not update the requested row in the target report.\n" >&2
  /bin/cat "$report_target" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq -- '- Manual rows passed: 1' "$status_output"; then
  printf "Recorder did not print updated manual acceptance status.\n" >&2
  /bin/cat "$status_output" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  s3_destination \
  Blocked \
  "Blocked pending dedicated S3-compatible provider credentials for acceptance." >/dev/null

if ! /usr/bin/grep -Fq '| s3_destination | S3-compatible destination | Blocked | Blocked pending dedicated S3-compatible provider credentials for acceptance.' "$report_target"; then
  printf "Recorder did not write blocked evidence.\n" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  s3_destination \
  Not\ run \
  "Manual evidence: TODO" >/dev/null

if ! /usr/bin/grep -Fq '| s3_destination | S3-compatible destination | Not run | Manual evidence: TODO |' "$report_target"; then
  printf "Recorder did not reset a row to Not run.\n" >&2
  exit 1
fi

expect_failure "unknown row id" \
  "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  unknown_row \
  Passed \
  "Manual evidence: this should not be accepted for an unknown row."

expect_failure "invalid result" \
  "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  settings_surface \
  Done \
  "Manual evidence: invalid result value should fail before writing."

expect_failure "thin passed evidence" \
  "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  settings_surface \
  Passed \
  "ok"

expect_failure "generated local-probe text" \
  "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" \
  "$report_link" \
  settings_surface \
  Passed \
  "Manual evidence: observed Settings. Local probe: Partial. Follow-up still required: do the manual check."

printf "Manual acceptance recorder self-test passed.\n"
