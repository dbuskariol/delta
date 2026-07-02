#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-rclone-local-acceptance.XXXXXX)"

cleanup() {
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

if [[ ! -x "$APP_PATH/Contents/MacOS/rclone" ]]; then
  printf "Bundled rclone is missing or not executable: %s\n" "$APP_PATH/Contents/MacOS/rclone" >&2
  exit 1
fi

RCLONE_CONFIG_PATH="$WORK_DIR/rclone.conf"
REMOTE_ROOT="$WORK_DIR/delta-acceptance"
REPOSITORY_PATH="$REMOTE_ROOT/repository"

/bin/mkdir -p "$REMOTE_ROOT"
/usr/bin/printf '[delta-local]\ntype = local\n' >"$RCLONE_CONFIG_PATH"

DELTA_ACCEPTANCE_RCLONE_REPOSITORY="rclone:delta-local:$REPOSITORY_PATH" \
RCLONE_CONFIG="$RCLONE_CONFIG_PATH" \
  "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" rclone "$APP_PATH"

printf "Installed rclone local-remote lifecycle acceptance passed for %s\n" "$APP_PATH"
