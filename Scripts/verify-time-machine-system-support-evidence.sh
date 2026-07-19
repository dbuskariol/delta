#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/lib/delta-release.sh
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP_PATH="${1:-/Applications/Delta.app}"
EVIDENCE="${2:-${DELTA_TIME_MACHINE_SYSTEM_ACCEPTANCE_EVIDENCE:-$ROOT_DIR/dist/time-machine-system-support/latest.txt}}"

[[ -d "$APP_PATH" ]] || delta_fail "installed app not found: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
[[ "$APP_PATH" == "/Applications/Delta.app" ]] \
  || delta_fail "Time Machine system-support evidence requires the exact canonical app at /Applications/Delta.app, not $APP_PATH"
[[ -e "$EVIDENCE" ]] || delta_fail "Time Machine system-support evidence was not found: $EVIDENCE"

resolve_evidence_path() {
  local path="$1"
  local target
  if [[ -L "$path" ]]; then
    target="$(/usr/bin/readlink "$path")"
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      path="$(dirname "$path")/$target"
    fi
  fi
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}

EVIDENCE="$(resolve_evidence_path "$EVIDENCE")"
[[ -f "$EVIDENCE" ]] || delta_fail "Time Machine system-support evidence is not a regular file: $EVIDENCE"

evidence_value() {
  local key="$1"
  local count value
  count="$(/usr/bin/awk -F= -v key="$key" '$1 == key { count += 1 } END { print count + 0 }' "$EVIDENCE")"
  [[ "$count" == "1" ]] || delta_fail "Time Machine system-support evidence must contain exactly one $key field"
  value="$(/usr/bin/awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$EVIDENCE")"
  [[ -n "$value" ]] || delta_fail "Time Machine system-support evidence has an empty $key field"
  printf '%s\n' "$value"
}

IFS=$'\t' read -r VERSION BUILD < <(delta_assert_release_metadata "$ROOT_DIR")
export DELTA_EXPECTED_RELEASE_VERSION="$VERSION"
export DELTA_EXPECTED_RELEASE_BUILD="$BUILD"
delta_assert_release_app "$APP_PATH" "$DELTA_EXPECTED_TEAM_ID"
delta_assert_notarized_app "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
HELPER_EXECUTABLE="$APP_PATH/Contents/MacOS/DeltaTimeMachineHelper"
APP_CDHASH="$(delta_signature_cdhash "$APP_PATH")"
HELPER_CDHASH="$(delta_signature_cdhash "$HELPER_EXECUTABLE")"
GIT_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"
HELPER_CDHASH_LOWER="$(/usr/bin/tr '[:upper:]' '[:lower:]' <<<"$HELPER_CDHASH")"
EVIDENCE_HELPER_CDHASH="$(evidence_value helper_cdhash)"
EVIDENCE_RUNTIME_HELPER_CODE_HASH="$(evidence_value runtime_helper_code_hash)"
EVIDENCE_HELPER_CDHASH_LOWER="$(/usr/bin/tr '[:upper:]' '[:lower:]' <<<"$EVIDENCE_HELPER_CDHASH")"
EVIDENCE_RUNTIME_HELPER_CODE_HASH_LOWER="$(/usr/bin/tr '[:upper:]' '[:lower:]' <<<"$EVIDENCE_RUNTIME_HELPER_CODE_HASH")"

[[ "$(evidence_value status)" == "Passed" ]] || delta_fail 'Time Machine system-support evidence did not pass'
[[ "$(evidence_value git_commit)" == "$GIT_COMMIT" ]] || delta_fail 'Time Machine system-support evidence belongs to a different source commit'
[[ "$(evidence_value app_path)" == "$APP_PATH" ]] || delta_fail 'Time Machine system-support evidence belongs to a different installed path'
[[ "$(evidence_value bundle_id)" == "$(delta_plist_value CFBundleIdentifier "$INFO_PLIST")" ]] || delta_fail 'Time Machine system-support evidence has a different bundle identifier'
[[ "$(evidence_value version)" == "$VERSION" ]] || delta_fail 'Time Machine system-support evidence has a different version'
[[ "$(evidence_value build)" == "$BUILD" ]] || delta_fail 'Time Machine system-support evidence has a different build'
[[ "$(evidence_value team_id)" == "$DELTA_EXPECTED_TEAM_ID" ]] || delta_fail 'Time Machine system-support evidence has a different signing team'
[[ "$(evidence_value app_cdhash)" == "$APP_CDHASH" ]] || delta_fail 'Time Machine system-support evidence has a different app CDHash'
[[ "$EVIDENCE_HELPER_CDHASH_LOWER" == "$HELPER_CDHASH_LOWER" ]] || delta_fail 'Time Machine system-support evidence has a different helper CDHash'
[[ "$EVIDENCE_RUNTIME_HELPER_CODE_HASH_LOWER" == "$HELPER_CDHASH_LOWER" ]] || delta_fail 'authenticated runtime helper hash does not match the exact embedded helper'
[[ "$(evidence_value initial_storage_service_status)" == "notRegistered" ]] || delta_fail 'acceptance did not begin with a clean storage-service registration'
[[ "$(evidence_value initial_setup_helper_status)" == "notRegistered" ]] || delta_fail 'acceptance did not begin with a clean setup-helper registration'
[[ "$(evidence_value registered_storage_service_status)" == "enabled" ]] || delta_fail 'storage service never became eligible to run'
[[ "$(evidence_value registered_setup_helper_status)" == "enabled" ]] || delta_fail 'setup helper never became eligible to run'
[[ "$(evidence_value authenticated_helper_readiness)" == "verified" ]] || delta_fail 'the exact running helper was not authenticated'
[[ "$(evidence_value cleanup_storage_service_status)" == "notRegistered" ]] || delta_fail 'acceptance did not clean up the storage-service registration'
[[ "$(evidence_value cleanup_setup_helper_status)" == "notRegistered" ]] || delta_fail 'acceptance did not clean up the setup-helper registration'

printf 'Time Machine system-support evidence verified for Delta %s (%s), commit %s, app CDHash %s, helper CDHash %s.\n' \
  "$VERSION" "$BUILD" "$GIT_COMMIT" "$APP_CDHASH" "$HELPER_CDHASH"
