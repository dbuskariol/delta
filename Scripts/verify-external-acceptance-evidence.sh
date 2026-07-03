#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_EXTERNAL_ACCEPTANCE_APP:-$ROOT_DIR/dist/Delta.app}}"
REPORT_DIR="${DELTA_EXTERNAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
HEAD_COMMIT="${DELTA_EXTERNAL_ACCEPTANCE_GIT_COMMIT:-$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)}"

REQUIRED_KINDS_RAW="${DELTA_EXTERNAL_ACCEPTANCE_REQUIRED_KINDS:-mounted sftp s3}"
REQUIRE_SFTP_FAILURE_PROBE="${DELTA_EXTERNAL_ACCEPTANCE_REQUIRE_SFTP_FAILURE_PROBE:-1}"
REPORT_FAILURES=()

fail() {
  printf "External acceptance evidence failed: %s\n" "$1" >&2
  exit 1
}

record_failure() {
  REPORT_FAILURES+=("$1")
}

normalize_kind_list() {
  local raw="$1"
  raw="${raw//,/ }"
  printf "%s\n" "$raw" | /usr/bin/awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i != "") {
          print tolower($i)
        }
      }
    }
  '
}

validate_kind() {
  case "$1" in
    mounted|sftp|rest|s3|b2|azure|gcs|swift|rclone|custom)
      ;;
    *)
      fail "unsupported external acceptance evidence kind '$1'. Expected mounted, sftp, rest, s3, b2, azure, gcs, swift, rclone, or custom."
      ;;
  esac
}

report_path_for_kind() {
  local kind="$1"
  local env_key="DELTA_EXTERNAL_ACCEPTANCE_$(printf "%s" "$kind" | /usr/bin/tr '[:lower:]' '[:upper:]')_REPORT"
  local configured="${!env_key:-}"
  if [[ -n "$configured" ]]; then
    printf "%s" "$configured"
  else
    printf "%s/external-%s-acceptance-latest.md" "$REPORT_DIR" "$kind"
  fi
}

required_environment_for_kind() {
  case "$1" in
    mounted)
      printf "mounted-network"
      ;;
    *)
      printf "real-external"
      ;;
  esac
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

  local runner
  local environment
  runner="$(report_value "$report" "Runner")"
  environment="$(report_value "$report" "Acceptance environment")"
  if [[ "$runner" != "Scripts/run-external-backend-acceptance.sh" || -z "$environment" ]]; then
    record_failure "$kind report at $report is not current installed external lifecycle evidence. Run Scripts/run-external-backend-acceptance.sh $kind /Applications/Delta.app against real infrastructure."
    return 1
  fi
  if [[ "$environment" != "$required_environment" ]]; then
    record_failure "$kind report was produced against '$environment', expected '$required_environment'. Localhost/local harness evidence is not sufficient for production readiness."
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

REQUIRED_KINDS=()
while IFS= read -r kind; do
  REQUIRED_KINDS+=("$kind")
done < <(normalize_kind_list "$REQUIRED_KINDS_RAW")
(( ${#REQUIRED_KINDS[@]} > 0 )) || fail "DELTA_EXTERNAL_ACCEPTANCE_REQUIRED_KINDS must include at least one backend kind."

for kind in "${REQUIRED_KINDS[@]}"; do
  validate_kind "$kind"
  report="$(report_path_for_kind "$kind")"
  verify_report "$kind" "$report" "$(required_environment_for_kind "$kind")" || true
  if [[ "$kind" == "sftp" && "$REQUIRE_SFTP_FAILURE_PROBE" == "1" ]]; then
    if [[ -f "$report" || -L "$report" ]]; then
      require_contains "$report" "- Wrong SFTP credential or target probe: Passed" || true
    fi
  fi
  if [[ "$kind" == "s3" && ( -f "$report" || -L "$report" ) ]]; then
    require_contains "$report" "- Missing credential probe: Passed" || true
  fi
done

if (( ${#REPORT_FAILURES[@]} > 0 )); then
  printf "External acceptance evidence failed:\n" >&2
  printf -- "- %s\n" "${REPORT_FAILURES[@]}" >&2
  exit 1
fi

printf "External acceptance evidence verified for required backend kinds (%s) at commit %s.\n" "${REQUIRED_KINDS[*]}" "$HEAD_COMMIT"
