#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-rest-local-acceptance.XXXXXX)"
RCLONE_PID=""

cleanup() {
  if [[ -n "$RCLONE_PID" ]]; then
    /bin/kill "$RCLONE_PID" >/dev/null 2>&1 || true
    wait "$RCLONE_PID" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf "%s\n" "$1" >&2
  if [[ -f "$WORK_DIR/rclone-rest.log" ]]; then
    printf "\nrclone serve restic log:\n" >&2
    /bin/cat "$WORK_DIR/rclone-rest.log" >&2
  fi
  exit "${2:-1}"
}

choose_port() {
  local port
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    port=$((40000 + RANDOM % 20000))
    if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      printf "%s\n" "$port"
      return
    fi
  done
  return 1
}

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
RCLONE="$APP_PATH/Contents/MacOS/rclone"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi
if [[ ! -x "$RCLONE" ]]; then
  fail "Bundled rclone is missing or not executable: $RCLONE"
fi

PORT="$(choose_port)" || fail "Could not find an available localhost port."
USERNAME="delta-user-$RANDOM"
PASSWORD="$(/usr/bin/uuidgen)-$(/usr/bin/uuidgen)"
SERVER_ROOT="$WORK_DIR/rest-root"
REPOSITORY_URL="rest:http://127.0.0.1:$PORT/delta-acceptance/repository/"

/bin/mkdir -p "$SERVER_ROOT"

"$RCLONE" serve restic \
  --addr "127.0.0.1:$PORT" \
  --user "$USERNAME" \
  --pass "$PASSWORD" \
  "$SERVER_ROOT" >"$WORK_DIR/rclone-rest.log" 2>&1 &
RCLONE_PID=$!
/bin/sleep 2
if ! /bin/kill -0 "$RCLONE_PID" >/dev/null 2>&1; then
  fail "Local REST server did not start."
fi

if ! /usr/bin/nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
  fail "Local REST server did not listen on localhost."
fi

DELTA_ACCEPTANCE_REST_REPOSITORY="$REPOSITORY_URL" \
RESTIC_REST_USERNAME="$USERNAME" \
RESTIC_REST_PASSWORD="$PASSWORD" \
  "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" rest "$APP_PATH"

printf "Installed local REST lifecycle acceptance passed for %s\n" "$APP_PATH"
