#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_EXTERNAL_ACCEPTANCE_APP:-$ROOT_DIR/dist/Delta.app}}"
REPORT_DIR="${DELTA_EXTERNAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
HEAD_COMMIT="${DELTA_EXTERNAL_ACCEPTANCE_GIT_COMMIT:-$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)}"

MOUNTED_REPORT="${DELTA_EXTERNAL_ACCEPTANCE_MOUNTED_REPORT:-$REPORT_DIR/external-mounted-acceptance-latest.md}"
SFTP_REPORT="${DELTA_EXTERNAL_ACCEPTANCE_SFTP_REPORT:-$REPORT_DIR/external-sftp-acceptance-latest.md}"
S3_REPORT="${DELTA_EXTERNAL_ACCEPTANCE_S3_REPORT:-$REPORT_DIR/external-s3-acceptance-latest.md}"
REQUIRE_SFTP_FAILURE_PROBE="${DELTA_EXTERNAL_ACCEPTANCE_REQUIRE_SFTP_FAILURE_PROBE:-1}"

fail() {
  printf "External acceptance evidence failed: %s\n" "$1" >&2
  exit 1
}

report_value() {
  local report="$1"
  local key="$2"
  /usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$report" 2>/dev/null || true
}

code_signature_value() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

require_contains() {
  local report="$1"
  local expected="$2"
  if ! /usr/bin/grep -Fq -- "$expected" "$report"; then
    fail "$report is missing expected evidence: $expected"
  fi
}

verify_report() {
  local kind="$1"
  local report="$2"
  local required_environment="$3"

  [[ -f "$report" || -L "$report" ]] || fail "$kind report not found at $report. Run Scripts/run-external-backend-acceptance.sh $kind /Applications/Delta.app against real infrastructure."

  require_contains "$report" "- Kind: $kind"
  require_contains "$report" "Installed external $kind lifecycle acceptance passed."
  require_contains "$report" "- Delta coordinator lifecycle: Yes"
  require_contains "$report" "- Automatic destination preparation runs: 1"
  require_contains "$report" "- No-change backup:"
  require_contains "$report" "- Incremental backup:"
  require_contains "$report" "- Restore browser entries verified:"
  require_contains "$report" "- Full restore status: Completed"
  require_contains "$report" "- Selected folder restore status: Completed"
  require_contains "$report" "- Destination check status: Completed"
  require_contains "$report" "- Cleanup runs:"
  require_contains "$report" "- Keychain items deleted on exit: Yes"
  require_contains "$report" "- Runner: Scripts/run-external-backend-acceptance.sh"

  local report_commit
  report_commit="$(report_value "$report" "Git Commit")"
  [[ "$report_commit" == "$HEAD_COMMIT" ]] || fail "$kind report is for commit ${report_commit:-unknown}, not current commit $HEAD_COMMIT."

  local environment
  environment="$(report_value "$report" "Acceptance environment")"
  [[ "$environment" == "$required_environment" ]] || fail "$kind report was produced against '${environment:-unknown}', expected '$required_environment'. Localhost/local harness evidence is not sufficient for production readiness."

  if [[ -d "$APP_PATH" ]]; then
    local app_cdhash
    local report_cdhash
    app_cdhash="$(code_signature_value "$APP_PATH" CDHash)"
    report_cdhash="$(report_value "$report" "App CDHash")"
    [[ -n "$report_cdhash" ]] || fail "$kind report does not record the app CDHash."
    [[ "$report_cdhash" == "$app_cdhash" ]] || fail "$kind report CDHash $report_cdhash does not match $APP_PATH CDHash $app_cdhash."
  fi
}

verify_report mounted "$MOUNTED_REPORT" mounted-network
verify_report sftp "$SFTP_REPORT" real-external
if [[ "$REQUIRE_SFTP_FAILURE_PROBE" == "1" ]]; then
  require_contains "$SFTP_REPORT" "- Wrong SFTP credential or target probe: Passed"
fi
verify_report s3 "$S3_REPORT" real-external
require_contains "$S3_REPORT" "- Missing credential probe: Passed"

printf "External acceptance evidence verified for mounted network, real SFTP, and real S3-compatible destinations at commit %s.\n" "$HEAD_COMMIT"
