#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-s3-local-acceptance.XXXXXX)"
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
  if [[ -f "$WORK_DIR/rclone-s3.log" ]]; then
    printf "\nrclone serve s3 log:\n" >&2
    /bin/cat "$WORK_DIR/rclone-s3.log" >&2
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
ACCESS_KEY="delta-access-$RANDOM"
SECRET_KEY="$(/usr/bin/uuidgen)-$(/usr/bin/uuidgen)"
BUCKET="delta-acceptance"
SERVER_ROOT="$WORK_DIR/s3-root"

/bin/mkdir -p "$SERVER_ROOT/$BUCKET"

"$RCLONE" serve s3 \
  --addr "127.0.0.1:$PORT" \
  --auth-key "$ACCESS_KEY,$SECRET_KEY" \
  "$SERVER_ROOT" >"$WORK_DIR/rclone-s3.log" 2>&1 &
RCLONE_PID=$!
/bin/sleep 2
if ! /bin/kill -0 "$RCLONE_PID" >/dev/null 2>&1; then
  fail "Local S3-compatible server did not start."
fi

DELTA_ACCEPTANCE_S3_REPOSITORY="s3:http://127.0.0.1:$PORT/$BUCKET/repository" \
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
AWS_DEFAULT_REGION="us-east-1" \
  "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" s3 "$APP_PATH"

printf "Installed local S3-compatible lifecycle acceptance passed for %s\n" "$APP_PATH"
