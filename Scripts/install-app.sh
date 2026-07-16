#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP_SOURCE="${1:-$ROOT_DIR/dist/Delta.app}"
INSTALL_DIR="${DELTA_INSTALL_DIR:-/Applications}"
APP_TARGET="$INSTALL_DIR/Delta.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$ROOT_DIR/Scripts/build-app.sh"
fi

if [[ ! -d "$APP_SOURCE" ]]; then
  printf "Delta.app was not found at %s\n" "$APP_SOURCE" >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_SOURCE"

SOURCE_INFO="$APP_SOURCE/Contents/Info.plist"
[[ "$(delta_plist_value CFBundleIdentifier "$SOURCE_INFO")" == "$DELTA_EXPECTED_BUNDLE_ID" ]] \
  || delta_fail 'install source has an unexpected bundle identifier'
[[ "$(delta_plist_value LSMinimumSystemVersion "$SOURCE_INFO")" == "$DELTA_EXPECTED_MINIMUM_SYSTEM" ]] \
  || delta_fail "install source must require macOS $DELTA_EXPECTED_MINIMUM_SYSTEM"

SIGNING_DETAILS="$(delta_codesign_details "$APP_SOURCE")"
/usr/bin/grep -Eq '^Authority=(Apple Development|Developer ID Application):' <<<"$SIGNING_DETAILS" \
  || delta_fail 'install source must have a stable Apple Development or Developer ID signature'
NEW_TEAM="$(delta_signature_team "$APP_SOURCE")"
[[ -n "$NEW_TEAM" && "$NEW_TEAM" != "not set" ]] \
  || delta_fail 'install source signature is missing its team identifier'
[[ "$NEW_TEAM" == "$DELTA_EXPECTED_TEAM_ID" ]] \
  || delta_fail "install source team $NEW_TEAM does not match expected team $DELTA_EXPECTED_TEAM_ID"
NEW_REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP_SOURCE" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$NEW_REQUIREMENT" ]] || delta_fail 'install source has no designated code requirement'

if [[ -d "$APP_TARGET" ]]; then
  CURRENT_INFO="$APP_TARGET/Contents/Info.plist"
  CURRENT_BUNDLE_ID="$(delta_plist_value CFBundleIdentifier "$CURRENT_INFO")"
  [[ -z "$CURRENT_BUNDLE_ID" || "$CURRENT_BUNDLE_ID" == "$DELTA_EXPECTED_BUNDLE_ID" ]] \
    || delta_fail "refusing to replace an app with bundle identifier $CURRENT_BUNDLE_ID at $APP_TARGET"

  CURRENT_DETAILS="$(/usr/bin/codesign -dvv "$APP_TARGET" 2>&1 || true)"
  CURRENT_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$CURRENT_DETAILS")"
  if [[ -n "$CURRENT_TEAM" && "$CURRENT_TEAM" != "not set" && "$CURRENT_TEAM" != "$NEW_TEAM" ]]; then
    delta_fail "refusing to replace a Delta install signed by a different team ($CURRENT_TEAM)"
  fi

  CURRENT_REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP_TARGET" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
  if [[ -n "$CURRENT_REQUIREMENT" && "$CURRENT_REQUIREMENT" != "$NEW_REQUIREMENT" \
    && "${DELTA_ALLOW_IDENTITY_MIGRATION:-0}" != "1" ]]; then
    delta_fail 'the installed app has a different designated requirement; refusing an identity change that could invalidate Keychain and privacy grants'
  fi
fi

/bin/mkdir -p "$INSTALL_DIR"
STAGING_PATH="$INSTALL_DIR/.Delta.installing.$$.app"
BACKUP_PATH="$INSTALL_DIR/.Delta.previous.$$.app"
HAD_PREVIOUS_INSTALL=0
INSTALL_COMPLETED=0

if [[ -d "$APP_TARGET" ]]; then
  HAD_PREVIOUS_INSTALL=1
fi

cleanup_install() {
  [[ -z "${STAGING_PATH:-}" ]] || /bin/rm -rf "$STAGING_PATH"
  if [[ "$INSTALL_COMPLETED" != "1" ]]; then
    if [[ "$HAD_PREVIOUS_INSTALL" == "1" && -d "$BACKUP_PATH" ]]; then
      /bin/rm -rf "$APP_TARGET"
      /bin/mv "$BACKUP_PATH" "$APP_TARGET"
    elif [[ "$HAD_PREVIOUS_INSTALL" == "0" ]]; then
      /bin/rm -rf "$APP_TARGET"
    fi
  fi
  if [[ -d "$BACKUP_PATH" ]]; then
    /bin/rm -rf "$BACKUP_PATH"
  fi
}
trap cleanup_install EXIT INT TERM

/bin/rm -rf "$STAGING_PATH" "$BACKUP_PATH"
/usr/bin/ditto "$APP_SOURCE" "$STAGING_PATH"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$STAGING_PATH"

quit_running_app() {
  /usr/bin/osascript -e 'tell application id "com.delta.backup" to quit' >/dev/null 2>&1 &
  local quit_pid=$!
  for _ in {1..20}; do
    if ! /bin/kill -0 "$quit_pid" >/dev/null 2>&1; then
      wait "$quit_pid" >/dev/null 2>&1 || true
      return
    fi
    /bin/sleep 0.25
  done
  /bin/kill "$quit_pid" >/dev/null 2>&1 || true
  wait "$quit_pid" >/dev/null 2>&1 || true
}

quit_running_app
for _ in {1..20}; do
  if ! /usr/bin/pgrep -x Delta >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done
if /usr/bin/pgrep -x Delta >/dev/null 2>&1; then
  /usr/bin/pkill -x Delta >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! /usr/bin/pgrep -x Delta >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.25
  done
fi

if [[ -d "$APP_TARGET" ]]; then
  /bin/mv "$APP_TARGET" "$BACKUP_PATH"
fi
if ! /bin/mv "$STAGING_PATH" "$APP_TARGET"; then
  delta_fail 'unable to atomically install the staged app'
fi
STAGING_PATH=""

"$ROOT_DIR/Scripts/verify-installed-app.sh" "$APP_TARGET"
/bin/rm -rf "$BACKUP_PATH"
INSTALL_COMPLETED=1

printf "Installed %s\n" "$APP_TARGET"
printf "Team identifier: %s\n" "$NEW_TEAM"
printf "The verified designated app identity was preserved.\n"
