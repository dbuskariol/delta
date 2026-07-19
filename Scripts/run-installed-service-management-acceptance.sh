#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
PREFERENCES_DOMAIN="com.delta.backup.preferences"
PAUSE_KEY="Delta.pausesScheduledBackups"

[[ -x "$DELTA_EXECUTABLE" ]] || {
  printf 'Installed Delta executable is missing: %s\n' "$DELTA_EXECUTABLE" >&2
  exit 1
}
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ "$(dirname "$APP_PATH")" != "/Applications" || "$APP_PATH" != *.app ]]; then
  printf 'Service Management acceptance requires an app installed directly in /Applications, not %s\n' "$APP_PATH" >&2
  exit 64
fi

service_action() {
  DELTA_ENABLE_SERVICE_MANAGEMENT_ACCEPTANCE=1 \
    "$DELTA_EXECUTABLE" --acceptance-scheduled-service "$1"
}

status_value() {
  service_action status | /usr/bin/awk -F': ' \
    '$1 == "Scheduled service status" && value == "" { value = $2 } END { print value }'
}

INITIAL_STATUS="$(status_value)"
ORIGINAL_PAUSE_VALUE="$(/usr/bin/defaults read "$PREFERENCES_DOMAIN" "$PAUSE_KEY" 2>/dev/null || true)"
ORIGINAL_PAUSE_WAS_SET=0
if [[ -n "$ORIGINAL_PAUSE_VALUE" ]]; then
  ORIGINAL_PAUSE_WAS_SET=1
fi

restore_state() {
  current_status="$(status_value 2>/dev/null || true)"
  case "$INITIAL_STATUS" in
    enabled|requiresApproval)
      if [[ "$current_status" != "enabled" && "$current_status" != "requiresApproval" ]]; then
        service_action register >/dev/null 2>&1 || true
      fi
      ;;
    notRegistered)
      if [[ "$current_status" == "enabled" || "$current_status" == "requiresApproval" ]]; then
        service_action unregister >/dev/null 2>&1 || true
      fi
      ;;
  esac

  if [[ "$ORIGINAL_PAUSE_WAS_SET" == "1" ]]; then
    case "$ORIGINAL_PAUSE_VALUE" in
      1|true|TRUE|yes|YES)
        /usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool true >/dev/null
        ;;
      0|false|FALSE|no|NO)
        /usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool false >/dev/null
        ;;
      *)
        printf 'Could not restore unexpected Scheduled Backups pause value: %s\n' "$ORIGINAL_PAUSE_VALUE" >&2
        ;;
    esac
  else
    /usr/bin/defaults delete "$PREFERENCES_DOMAIN" "$PAUSE_KEY" >/dev/null 2>&1 || true
  fi
}
trap restore_state EXIT INT TERM

case "$INITIAL_STATUS" in
  enabled|requiresApproval|notRegistered) ;;
  *)
    printf 'Installed Service Management discovery failed before lifecycle testing: %s\n' "$INITIAL_STATUS" >&2
    exit 1
    ;;
esac

# Prevent the RunAtLoad registration probe from starting real scheduled work.
/usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool true >/dev/null

if [[ "$INITIAL_STATUS" == "enabled" || "$INITIAL_STATUS" == "requiresApproval" ]]; then
  service_action unregister >/dev/null
  UNREGISTERED_STATUS="$(status_value)"
  [[ "$UNREGISTERED_STATUS" == "notRegistered" ]] || {
    printf 'Service Management did not rediscover the unregistered bundled agent: %s\n' "$UNREGISTERED_STATUS" >&2
    exit 1
  }
else
  UNREGISTERED_STATUS="$INITIAL_STATUS"
fi

service_action register >/dev/null
REGISTERED_STATUS="$(status_value)"
[[ "$REGISTERED_STATUS" == "enabled" || "$REGISTERED_STATUS" == "requiresApproval" ]] || {
  printf 'Service Management registration did not reach an accepted state: %s\n' "$REGISTERED_STATUS" >&2
  exit 1
}

printf 'Installed Service Management lifecycle acceptance passed.\n'
printf -- '- App: %s\n' "$APP_PATH"
printf -- '- Initial status: %s\n' "$INITIAL_STATUS"
printf -- '- After unregister: %s\n' "$UNREGISTERED_STATUS"
printf -- '- After register: %s\n' "$REGISTERED_STATUS"
