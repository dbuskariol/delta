#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/lib/delta-release.sh
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP_PATH="${1:-/Applications/Delta.app}"
OUTPUT_DIR="${DELTA_TIME_MACHINE_SYSTEM_ACCEPTANCE_DIR:-$ROOT_DIR/dist/time-machine-system-support}"
APPROVAL_TIMEOUT_SECONDS="${DELTA_TIME_MACHINE_APPROVAL_TIMEOUT_SECONDS:-600}"
POLL_INTERVAL_SECONDS=2

case "$APPROVAL_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    delta_fail 'DELTA_TIME_MACHINE_APPROVAL_TIMEOUT_SECONDS must be a nonnegative integer'
    ;;
esac

[[ -d "$APP_PATH" ]] || delta_fail "installed app not found: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
[[ "$APP_PATH" == "/Applications/Delta.app" ]] \
  || delta_fail "Time Machine system-support acceptance requires the exact canonical app at /Applications/Delta.app, not $APP_PATH"

IFS=$'\t' read -r VERSION BUILD < <(delta_assert_release_metadata "$ROOT_DIR")
export DELTA_EXPECTED_RELEASE_VERSION="$VERSION"
export DELTA_EXPECTED_RELEASE_BUILD="$BUILD"
delta_assert_release_app "$APP_PATH" "$DELTA_EXPECTED_TEAM_ID"
delta_assert_notarized_app "$APP_PATH"

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
HELPER_EXECUTABLE="$APP_PATH/Contents/MacOS/DeltaTimeMachineHelper"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -x "$DELTA_EXECUTABLE" ]] || delta_fail "Delta executable is missing: $DELTA_EXECUTABLE"
[[ -x "$HELPER_EXECUTABLE" ]] || delta_fail "Time Machine setup helper is missing: $HELPER_EXECUTABLE"

support_action() {
  DELTA_ENABLE_TIME_MACHINE_SYSTEM_ACCEPTANCE=1 \
    "$DELTA_EXECUTABLE" --acceptance-time-machine-system-support "$1"
}

status_value() {
  local output="$1"
  local label="$2"
  /usr/bin/awk -F': ' -v label="$label" \
    '$1 == label && value == "" { value = $2 } END { print value }' \
    <<<"$output"
}

read_statuses() {
  local output
  output="$(support_action status)"
  CURRENT_APP_INSTALLATION="$(status_value "$output" 'Time Machine app installation')"
  CURRENT_SERVICE_STATUS="$(status_value "$output" 'Time Machine storage service status')"
  CURRENT_HELPER_STATUS="$(status_value "$output" 'Time Machine setup helper status')"
  CURRENT_HELPER_EXECUTABLE="$(status_value "$output" 'Time Machine setup helper executable')"
  CURRENT_HELPER_CODE_HASH="$(status_value "$output" 'Time Machine setup helper code hash')"
}

registration_started=0
cleanup_complete=0

cleanup_registrations() {
  local attempt
  if [[ "$registration_started" != "1" || "$cleanup_complete" == "1" ]]; then
    return
  fi
  support_action unregister >/dev/null 2>&1 || true
  for attempt in {1..15}; do
    read_statuses 2>/dev/null || true
    if [[ "${CURRENT_SERVICE_STATUS:-}" == "notRegistered" \
      && "${CURRENT_HELPER_STATUS:-}" == "notRegistered" ]]; then
      cleanup_complete=1
      return
    fi
    /bin/sleep 1
  done
}

handle_signal() {
  local status="$1"
  trap - EXIT INT TERM
  cleanup_registrations
  exit "$status"
}
trap cleanup_registrations EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

read_statuses
[[ "$CURRENT_APP_INSTALLATION" == "canonical" ]] \
  || delta_fail "installed app was not reported as canonical: $CURRENT_APP_INSTALLATION"
[[ "$CURRENT_HELPER_EXECUTABLE" == "present" ]] \
  || delta_fail "installed helper was not executable: $CURRENT_HELPER_EXECUTABLE"
[[ "$CURRENT_SERVICE_STATUS" == "notRegistered" \
  && "$CURRENT_HELPER_STATUS" == "notRegistered" ]] \
  || delta_fail "clean first-registration acceptance requires both Time Machine services to begin notRegistered; storage=$CURRENT_SERVICE_STATUS helper=$CURRENT_HELPER_STATUS"

INITIAL_SERVICE_STATUS="$CURRENT_SERVICE_STATUS"
INITIAL_HELPER_STATUS="$CURRENT_HELPER_STATUS"
registration_started=1
support_action register >/dev/null

deadline=$((SECONDS + APPROVAL_TIMEOUT_SECONDS))
approval_message_printed=0
while true; do
  read_statuses
  if [[ "$CURRENT_SERVICE_STATUS" == "enabled" \
    && "$CURRENT_HELPER_STATUS" == "enabled" ]]; then
    break
  fi
  case "$CURRENT_SERVICE_STATUS:$CURRENT_HELPER_STATUS" in
    enabled:requiresApproval|requiresApproval:enabled|requiresApproval:requiresApproval)
      if [[ "$approval_message_printed" == "0" ]]; then
        printf '%s\n' \
          'macOS registered Delta system support and is waiting for administrator approval in System Settings > General > Login Items & Extensions.'
        approval_message_printed=1
      fi
      ;;
    *)
      delta_fail "Time Machine registration entered an invalid state; storage=$CURRENT_SERVICE_STATUS helper=$CURRENT_HELPER_STATUS"
      ;;
  esac
  if (( SECONDS >= deadline )); then
    delta_fail "administrator approval did not reach enabled state within ${APPROVAL_TIMEOUT_SECONDS}s; storage=$CURRENT_SERVICE_STATUS helper=$CURRENT_HELPER_STATUS"
  fi
  /bin/sleep "$POLL_INTERVAL_SECONDS"
done

REGISTERED_SERVICE_STATUS="$CURRENT_SERVICE_STATUS"
REGISTERED_HELPER_STATUS="$CURRENT_HELPER_STATUS"
VERIFY_OUTPUT="$(support_action verify)"
RUNTIME_READINESS="$(status_value "$VERIFY_OUTPUT" 'Time Machine setup helper readiness')"
RUNTIME_HELPER_CODE_HASH="$(status_value "$VERIFY_OUTPUT" 'Time Machine setup helper code hash')"
[[ "$RUNTIME_READINESS" == "verified" ]] \
  || delta_fail "authenticated setup-helper readiness was not verified: $RUNTIME_READINESS"

SIGNED_HELPER_CDHASH="$(delta_signature_cdhash "$HELPER_EXECUTABLE")"
[[ -n "$SIGNED_HELPER_CDHASH" && -n "$RUNTIME_HELPER_CODE_HASH" ]] \
  || delta_fail 'the installed or running helper code hash was unavailable'
SIGNED_HELPER_CDHASH_LOWER="$(/usr/bin/tr '[:upper:]' '[:lower:]' <<<"$SIGNED_HELPER_CDHASH")"
RUNTIME_HELPER_CODE_HASH_LOWER="$(/usr/bin/tr '[:upper:]' '[:lower:]' <<<"$RUNTIME_HELPER_CODE_HASH")"
[[ "$SIGNED_HELPER_CDHASH_LOWER" == "$RUNTIME_HELPER_CODE_HASH_LOWER" ]] \
  || delta_fail "the authenticated running helper hash does not match the exact embedded helper; signed=$SIGNED_HELPER_CDHASH running=$RUNTIME_HELPER_CODE_HASH"

support_action unregister >/dev/null
for _attempt in {1..15}; do
  read_statuses
  if [[ "$CURRENT_SERVICE_STATUS" == "notRegistered" \
    && "$CURRENT_HELPER_STATUS" == "notRegistered" ]]; then
    cleanup_complete=1
    break
  fi
  /bin/sleep 1
done
[[ "$cleanup_complete" == "1" ]] \
  || delta_fail "public Service Management cleanup did not complete; storage=$CURRENT_SERVICE_STATUS helper=$CURRENT_HELPER_STATUS"

APP_CDHASH="$(delta_signature_cdhash "$APP_PATH")"
GIT_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"
TIMESTAMP="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/bin/mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/Delta-time-machine-system-support-${TIMESTAMP//[:]/}.txt"
TEMPORARY="$(/usr/bin/mktemp "$OUTPUT_DIR/.time-machine-system-support.XXXXXX")"
{
  printf 'status=Passed\n'
  printf 'recorded_at=%s\n' "$TIMESTAMP"
  printf 'git_commit=%s\n' "$GIT_COMMIT"
  printf 'app_path=%s\n' "$APP_PATH"
  printf 'bundle_id=%s\n' "$(delta_plist_value CFBundleIdentifier "$INFO_PLIST")"
  printf 'version=%s\n' "$VERSION"
  printf 'build=%s\n' "$BUILD"
  printf 'host_macos=%s\n' "$(/usr/bin/sw_vers -productVersion)"
  printf 'host_build=%s\n' "$(/usr/bin/sw_vers -buildVersion)"
  printf 'team_id=%s\n' "$(delta_signature_team "$APP_PATH")"
  printf 'app_cdhash=%s\n' "$APP_CDHASH"
  printf 'helper_cdhash=%s\n' "$SIGNED_HELPER_CDHASH"
  printf 'runtime_helper_code_hash=%s\n' "$RUNTIME_HELPER_CODE_HASH"
  printf 'initial_storage_service_status=%s\n' "$INITIAL_SERVICE_STATUS"
  printf 'initial_setup_helper_status=%s\n' "$INITIAL_HELPER_STATUS"
  printf 'registered_storage_service_status=%s\n' "$REGISTERED_SERVICE_STATUS"
  printf 'registered_setup_helper_status=%s\n' "$REGISTERED_HELPER_STATUS"
  printf 'authenticated_helper_readiness=%s\n' "$RUNTIME_READINESS"
  printf 'cleanup_storage_service_status=%s\n' "$CURRENT_SERVICE_STATUS"
  printf 'cleanup_setup_helper_status=%s\n' "$CURRENT_HELPER_STATUS"
} >"$TEMPORARY"
/bin/mv -f "$TEMPORARY" "$OUTPUT"
LATEST_TEMP="$OUTPUT_DIR/.latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TEMP"
/bin/mv -f "$LATEST_TEMP" "$OUTPUT_DIR/latest.txt"
trap - EXIT INT TERM

printf 'Installed Time Machine system-support acceptance passed.\n'
printf -- '- App: %s\n' "$APP_PATH"
printf -- '- Candidate: %s (%s), commit %s, CDHash %s\n' "$VERSION" "$BUILD" "$GIT_COMMIT" "$APP_CDHASH"
printf -- '- Authenticated helper CDHash: %s\n' "$SIGNED_HELPER_CDHASH"
printf -- '- Evidence: %s\n' "$OUTPUT"
