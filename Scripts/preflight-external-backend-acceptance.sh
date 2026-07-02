#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${1:-all}"
APP_PATH="${2:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_EXTERNAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

usage() {
  cat >&2 <<'EOF'
usage: Scripts/preflight-external-backend-acceptance.sh [all|mounted|sftp|rest|s3|b2|azure|gcs|swift|rclone|custom] [Delta.app]

Validates the configured external acceptance backend environment without
initializing repositories, writing backup data, or running restore/check/cleanup.
For a single backend, the command exits non-zero unless that backend is ready.
For "all", missing backends are reported as Not Configured; configured but invalid
backends still fail the command.
EOF
}

fail() {
  printf "%s\n" "$1" >&2
  exit "${2:-1}"
}

mount_record_for_path() {
  local directory="$1"
  local line
  while IFS= read -r line; do
    case "$line" in
      *" on $directory ("*)
        printf "%s" "$line"
        return
        ;;
    esac
  done < <(/sbin/mount)
}

mount_filesystem_type() {
  local mount_record="$1"
  printf "%s" "$mount_record" | /usr/bin/sed -E 's/^.* \(([^,)]*).*$/\1/'
}

is_network_mount_type() {
  case "$1" in
    smbfs|nfs|nfs4|afpfs|webdav|fusefs.sshfs|sshfs)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prepare_mounted_repository_environment() {
  local mounted_path="${DELTA_ACCEPTANCE_MOUNTED_PATH:-}"
  [[ -n "$mounted_path" ]] || return 0
  local mount_record
  local mount_type
  mounted_path="$(cd "$mounted_path" 2>/dev/null && /bin/pwd -P || true)"
  [[ -n "$mounted_path" && -d "$mounted_path" ]] || fail "Mounted acceptance path is not a readable directory."
  case "$mounted_path" in
    /Volumes/*)
      ;;
    *)
      fail "Mounted acceptance path must live under /Volumes to prove mounted network-drive behavior."
      ;;
  esac
  mount_record="$(mount_record_for_path "$mounted_path")"
  [[ -n "$mount_record" ]] || fail "Mounted acceptance path was not found in the system mount table: $mounted_path"
  mount_type="$(mount_filesystem_type "$mount_record")"
  if ! is_network_mount_type "$mount_type"; then
    fail "Mounted acceptance path must be a network filesystem such as SMB or NFS. Found '$mount_type' for $mounted_path."
  fi
  COMMAND_ENV+=("DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH=$mounted_path/DeltaExternalAcceptance.preflight")
}

case "$KIND" in
  all|mounted|sftp|rest|s3|b2|azure|gcs|swift|rclone|custom)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    fail "Unsupported external backend preflight kind: $KIND" 64
    ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-external-preflight-$KIND-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/external-preflight-$KIND-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t "delta-external-preflight-$KIND.XXXXXX")"
STDOUT_FILE="$WORK_DIR/preflight.stdout"
STDERR_FILE="$WORK_DIR/preflight.stderr"

cleanup() {
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

declare -a COMMAND_ENV=(
  "DELTA_ENABLE_EXTERNAL_PREFLIGHT_ACCEPTANCE=1"
)

if [[ "$KIND" != "all" ]]; then
  COMMAND_ENV+=("DELTA_EXTERNAL_ACCEPTANCE_KIND=$KIND")
fi

if [[ "$KIND" == "all" || "$KIND" == "mounted" ]]; then
  prepare_mounted_repository_environment
fi

set +e
/usr/bin/env "${COMMAND_ENV[@]}" "$DELTA_EXECUTABLE" --acceptance-external-preflight >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ -s "$STDOUT_FILE" ]]; then
  /bin/cp "$STDOUT_FILE" "$OUTPUT"
else
  {
    printf "# Delta External Backend Acceptance Preflight\n\n"
    printf "Preflight did not produce a report.\n"
  } >"$OUTPUT"
fi

if [[ -s "$STDERR_FILE" ]]; then
  {
    printf "\n## Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >>"$OUTPUT"
fi

LATEST_TMP="$OUTPUT_DIR/.external-preflight-$KIND-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote external backend preflight to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
if [[ "$STATUS" -ne 0 ]]; then
  printf "External backend preflight failed for %s. See %s\n" "$KIND" "$OUTPUT" >&2
  exit "$STATUS"
fi
printf "External backend preflight passed for %s using %s\n" "$KIND" "$APP_PATH"
