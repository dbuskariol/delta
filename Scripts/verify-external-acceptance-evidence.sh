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
REPORT_FAILURES=()

fail() {
  printf "External acceptance evidence failed: %s\n" "$1" >&2
  exit 1
}

record_failure() {
  REPORT_FAILURES+=("$1")
}

canonical_app_path() {
  local app="$1"
  [[ -d "$app" ]] || fail "app bundle not found at $app."
  (cd "$app" && /bin/pwd -P)
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

require_report_value() {
  local kind="$1"
  local report="$2"
  local key="$3"
  local value
  value="$(report_value "$report" "$key")"
  if [[ -z "$value" ]]; then
    record_failure "$kind report at $report does not record '$key'."
    return 1
  fi
  printf "%s" "$value"
}

require_report_value_equals() {
  local kind="$1"
  local report="$2"
  local key="$3"
  local expected="$4"
  local value
  value="$(report_value "$report" "$key")"
  if [[ -z "$value" ]]; then
    record_failure "$kind report at $report does not record '$key'."
    return 1
  fi
  if [[ "$value" != "$expected" ]]; then
    record_failure "$kind report at $report records '$key' as '$value', expected '$expected'."
    return 1
  fi
}

require_contains() {
  local report="$1"
  local expected="$2"
  if ! /usr/bin/grep -Fq -- "$expected" "$report"; then
    record_failure "$report is missing expected evidence: $expected"
    return 1
  fi
}

verify_report() {
  local kind="$1"
  local report="$2"
  local required_environment="$3"
  local failed=0

  if [[ ! -f "$report" && ! -L "$report" ]]; then
    record_failure "$kind report not found at $report. Run Scripts/run-external-backend-acceptance.sh $kind /Applications/Delta.app against real infrastructure."
    return 1
  fi

  require_report_value "$kind" "$report" "Generated" >/dev/null || failed=1
  require_report_value_equals "$kind" "$report" "App" "$APP_PATH" || failed=1
  require_report_value_equals "$kind" "$report" "Executable" "$APP_EXECUTABLE" || failed=1
  require_report_value_equals "$kind" "$report" "Restic" "$APP_RESTIC" || failed=1
  require_contains "$report" "- Kind: $kind" || failed=1
  require_contains "$report" "Installed external $kind lifecycle acceptance passed." || failed=1
  require_contains "$report" "- Delta coordinator lifecycle: Yes" || failed=1
  require_contains "$report" "- Automatic destination preparation runs: 1" || failed=1
  require_contains "$report" "- First backup status: Completed" || failed=1
  require_contains "$report" "- No-change backup:" || failed=1
  require_contains "$report" "- Incremental backup:" || failed=1
  require_contains "$report" "- Cached restore points:" || failed=1
  require_contains "$report" "- Latest restore point:" || failed=1
  require_contains "$report" "- Restore browser entries verified:" || failed=1
  require_contains "$report" "- Full restore status: Completed" || failed=1
  require_contains "$report" "- Selected folder restore status: Completed" || failed=1
  require_contains "$report" "- Destination check status: Completed" || failed=1
  require_contains "$report" "- Cleanup runs:" || failed=1
  require_contains "$report" "- Stored backup jobs: 3" || failed=1
  require_contains "$report" "- Stored restore jobs: 2" || failed=1
  require_contains "$report" "- Keychain items deleted on exit: Yes" || failed=1
  require_contains "$report" "- Runner: Scripts/run-external-backend-acceptance.sh" || failed=1

  local report_commit
  report_commit="$(report_value "$report" "Git Commit")"
  if [[ "$report_commit" != "$HEAD_COMMIT" ]]; then
    record_failure "$kind report is for commit ${report_commit:-unknown}, not current commit $HEAD_COMMIT."
    failed=1
  fi

  local environment
  environment="$(report_value "$report" "Acceptance environment")"
  if [[ "$environment" != "$required_environment" ]]; then
    record_failure "$kind report was produced against '${environment:-unknown}', expected '$required_environment'. Localhost/local harness evidence is not sufficient for production readiness."
    failed=1
  fi

  local report_cdhash
  report_cdhash="$(report_value "$report" "App CDHash")"
  if [[ -z "$report_cdhash" ]]; then
    record_failure "$kind report at $report does not record the app CDHash."
    failed=1
  elif [[ "$report_cdhash" != "$APP_CDHASH" ]]; then
    record_failure "$kind report CDHash $report_cdhash does not match $APP_PATH CDHash $APP_CDHASH."
    failed=1
  fi

  return "$failed"
}

APP_PATH="$(canonical_app_path "$APP_PATH")"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
APP_RESTIC="$APP_PATH/Contents/MacOS/restic"
[[ -x "$APP_EXECUTABLE" ]] || fail "Delta executable is missing or not executable at $APP_EXECUTABLE."
[[ -x "$APP_RESTIC" ]] || fail "bundled restic is missing or not executable at $APP_RESTIC."
APP_CDHASH="$(code_signature_value "$APP_PATH" CDHash)"
[[ -n "$APP_CDHASH" ]] || fail "could not read the app CDHash for $APP_PATH."

verify_report mounted "$MOUNTED_REPORT" mounted-network || true
verify_report sftp "$SFTP_REPORT" real-external || true
if [[ "$REQUIRE_SFTP_FAILURE_PROBE" == "1" ]]; then
  if [[ -f "$SFTP_REPORT" || -L "$SFTP_REPORT" ]]; then
    require_contains "$SFTP_REPORT" "- Wrong SFTP credential or target probe: Passed" || true
  fi
fi
verify_report s3 "$S3_REPORT" real-external || true
if [[ -f "$S3_REPORT" || -L "$S3_REPORT" ]]; then
  require_contains "$S3_REPORT" "- Missing credential probe: Passed" || true
fi

if (( ${#REPORT_FAILURES[@]} > 0 )); then
  printf "External acceptance evidence failed:\n" >&2
  printf -- "- %s\n" "${REPORT_FAILURES[@]}" >&2
  exit 1
fi

printf "External acceptance evidence verified for mounted network, real SFTP, and real S3-compatible destinations at commit %s.\n" "$HEAD_COMMIT"
