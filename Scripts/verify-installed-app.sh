#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Delta.app}"

if [[ ! -d "$APP" ]]; then
  printf "Installed Delta app was not found at %s\n" "$APP" >&2
  exit 1
fi
APP="$(cd "$APP" && pwd -P)"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"

SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
if ! /usr/bin/grep -q '^TeamIdentifier=' <<<"$SIGNING_DETAILS"; then
  printf "Installed Delta app has no signing TeamIdentifier.\n" >&2
  exit 1
fi
if /usr/bin/grep -q '^TeamIdentifier=not set$' <<<"$SIGNING_DETAILS"; then
  printf "Installed Delta app is ad-hoc signed.\n" >&2
  exit 1
fi

if [[ "${DELTA_VERIFY_INSTALLED_LAUNCH:-0}" == "1" ]]; then
  if [[ "$(dirname "$APP")" != "/Applications" || "$APP" != *.app ]]; then
    printf "Identity-sensitive launch acceptance requires an app installed directly in /Applications, not %s\n" "$APP" >&2
    exit 64
  fi
  LAUNCH_LOG="$(/usr/bin/mktemp -t delta-installed-launch.XXXXXX)"
  "$APP/Contents/MacOS/Delta" >"$LAUNCH_LOG" 2>&1 &
  DELTA_PID=$!
  /bin/sleep 2
  if ! /bin/kill -0 "$DELTA_PID" >/dev/null 2>&1; then
    /bin/cat "$LAUNCH_LOG" >&2
    /bin/rm -f "$LAUNCH_LOG"
    exit 1
  fi
  /bin/kill "$DELTA_PID" >/dev/null 2>&1 || true
  wait "$DELTA_PID" >/dev/null 2>&1 || true
  /bin/rm -f "$LAUNCH_LOG"
fi

"$APP/Contents/Resources/DeltaAgent" --status
DELTA_ENABLE_SERVICE_MANAGEMENT_ACCEPTANCE=1 \
  "$APP/Contents/MacOS/Delta" --acceptance-scheduled-service status

AGENT_DRY_RUN_OUTPUT="$("$APP/Contents/Resources/DeltaAgent" --dry-run 2>&1)"
if [[ "$AGENT_DRY_RUN_OUTPUT" != *"dry run did not start scheduled backups"* ]]; then
  printf "Installed DeltaAgent dry-run did not report non-mutating behavior: %s\n" "$AGENT_DRY_RUN_OUTPUT" >&2
  exit 1
fi
printf "%s\n" "$AGENT_DRY_RUN_OUTPUT"

ISOLATED_SUPPORT="$(/usr/bin/mktemp -d -t delta-installed-support.XXXXXX)"
set +e
AGENT_ISOLATED_OUTPUT="$(DELTA_APP_SUPPORT_DIR="$ISOLATED_SUPPORT" "$APP/Contents/Resources/DeltaAgent" 2>&1)"
AGENT_ISOLATED_STATUS=$?
set -e
if [[ "$AGENT_ISOLATED_STATUS" -ne 0 || "$AGENT_ISOLATED_OUTPUT" != *"completed 0 due backup run(s)"* ]]; then
  printf "Installed DeltaAgent isolated due-run failed. status=%s output=%s\n" "$AGENT_ISOLATED_STATUS" "$AGENT_ISOLATED_OUTPUT" >&2
  /bin/rm -rf "$ISOLATED_SUPPORT"
  exit 1
fi
if [[ ! -f "$ISOLATED_SUPPORT/Delta.sqlite" ]]; then
  printf "Installed DeltaAgent did not create isolated app data at %s\n" "$ISOLATED_SUPPORT/Delta.sqlite" >&2
  /bin/rm -rf "$ISOLATED_SUPPORT"
  exit 1
fi
/bin/rm -rf "$ISOLATED_SUPPORT"
printf "%s\n" "$AGENT_ISOLATED_OUTPUT"

"$APP/Contents/MacOS/restic" version
RCLONE_VERSION_OUTPUT="$("$APP/Contents/MacOS/rclone" version)"
printf '%s\n' "${RCLONE_VERSION_OUTPUT%%$'\n'*}"

set +e
SECRET_BRIDGE_MISSING_OUTPUT="$("$APP/Contents/MacOS/DeltaSecretBridge" 2>&1)"
SECRET_BRIDGE_MISSING_STATUS=$?
SECRET_BRIDGE_EXTRA_OUTPUT="$("$APP/Contents/MacOS/DeltaSecretBridge" account extra 2>&1)"
SECRET_BRIDGE_EXTRA_STATUS=$?
set -e
if [[ "$SECRET_BRIDGE_MISSING_STATUS" -ne 64 || "$SECRET_BRIDGE_MISSING_OUTPUT" != *"expected exactly one keychain account"* ]]; then
  printf "Installed DeltaSecretBridge did not fail closed for a missing account. status=%s output=%s\n" "$SECRET_BRIDGE_MISSING_STATUS" "$SECRET_BRIDGE_MISSING_OUTPUT" >&2
  exit 1
fi
if [[ "$SECRET_BRIDGE_EXTRA_STATUS" -ne 64 || "$SECRET_BRIDGE_EXTRA_OUTPUT" != *"expected exactly one keychain account"* ]]; then
  printf "Installed DeltaSecretBridge did not fail closed for extra arguments. status=%s output=%s\n" "$SECRET_BRIDGE_EXTRA_STATUS" "$SECRET_BRIDGE_EXTRA_OUTPUT" >&2
  exit 1
fi
printf "%s\n" "$SECRET_BRIDGE_MISSING_OUTPUT"

printf "Installed Delta smoke verification passed for %s\n" "$APP"
