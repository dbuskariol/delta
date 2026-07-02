#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

/bin/mkdir -p "$INSTALL_DIR"
/bin/rm -rf "$APP_TARGET"
/usr/bin/ditto "$APP_SOURCE" "$APP_TARGET"
"$ROOT_DIR/Scripts/verify-installed-app.sh" "$APP_TARGET"

printf "Installed %s\n" "$APP_TARGET"
