#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_MOUNTED_VOLUME_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-mounted-volume-acceptance.XXXXXX)"
VOLUME_NAME="DeltaAcceptance-$RANDOM-$$"
IMAGE_PATH="$WORK_DIR/$VOLUME_NAME.dmg"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
STDOUT_FILE="$WORK_DIR/mounted-volume.stdout"
STDERR_FILE="$WORK_DIR/mounted-volume.stderr"
SUPPORT_DIR="$WORK_DIR/support"
DETACHED=0

cleanup() {
  if [[ "$DETACHED" -eq 0 && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || \
      /usr/bin/hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf "%s\n" "$1" >&2
  if [[ -f "$STDERR_FILE" ]]; then
    printf "\nstandard error:\n" >&2
    /bin/cat "$STDERR_FILE" >&2
  fi
  if [[ -f "$STDOUT_FILE" ]]; then
    printf "\nstandard output:\n" >&2
    /bin/cat "$STDOUT_FILE" >&2
  fi
  exit "${2:-1}"
}

write_report() {
  local message="$1"
  {
    printf "# Delta Installed Mounted Volume Acceptance\n\n"
    printf "%s\n\n" "$message"
    printf -- "- App: %s\n" "$APP_PATH"
    printf -- "- Volume: %s\n" "$MOUNT_POINT"
    printf -- "- Image: %s\n\n" "$IMAGE_PATH"
    if [[ -f "$STDOUT_FILE" ]]; then
      printf "## Standard Output\n\n"
      printf '```text\n'
      /bin/cat "$STDOUT_FILE"
      printf '```\n\n'
    fi
    if [[ -f "$STDERR_FILE" ]]; then
      printf "## Standard Error\n\n"
      printf '```text\n'
      /bin/cat "$STDERR_FILE"
      printf '```\n'
    fi
  } >"$OUTPUT"
}

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-mounted-volume-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-mounted-volume-latest.md"

/usr/bin/hdiutil create \
  -size 512m \
  -fs APFS \
  -volname "$VOLUME_NAME" \
  "$IMAGE_PATH" >/dev/null

/usr/bin/hdiutil attach "$IMAGE_PATH" \
  -mountpoint "$MOUNT_POINT" \
  -nobrowse \
  -quiet

if [[ ! -d "$MOUNT_POINT" ]]; then
  fail "Mounted acceptance volume was not mounted at $MOUNT_POINT"
fi

case "$MOUNT_POINT" in
  /Volumes/*)
    ;;
  *)
    fail "Mounted acceptance volume did not mount under /Volumes: $MOUNT_POINT"
    ;;
esac

REPOSITORY_PATH="$MOUNT_POINT/delta-acceptance/repository"
/bin/mkdir -p "$REPOSITORY_PATH"

set +e
DELTA_ENABLE_EXTERNAL_LIFECYCLE_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
DELTA_EXTERNAL_ACCEPTANCE_KIND="mounted" \
DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH="$REPOSITORY_PATH" \
  "$DELTA_EXECUTABLE" --acceptance-external-lifecycle >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  write_report "Installed mounted-volume lifecycle acceptance failed."
  fail "Installed mounted-volume lifecycle acceptance failed. See $OUTPUT" "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  write_report "Installed mounted-volume lifecycle acceptance failed because stderr was not empty."
  fail "Installed mounted-volume lifecycle acceptance failed. See $OUTPUT"
fi

for expected in \
  "Installed external mounted lifecycle acceptance passed." \
  "Delta coordinator lifecycle: Yes" \
  "Automatic destination preparation runs: 1" \
  "No-change backup:" \
  "Incremental backup:" \
  "Restore browser entries verified:" \
  "Selected folder restore status:" \
  "Cleanup runs:"
do
  if ! /usr/bin/grep -Fq "$expected" "$STDOUT_FILE"; then
    write_report "Installed mounted-volume lifecycle acceptance failed because output was missing: $expected"
    fail "Installed mounted-volume lifecycle acceptance output was missing: $expected"
  fi
done

if [[ ! -d "$REPOSITORY_PATH" || ! -f "$REPOSITORY_PATH/config" ]]; then
  write_report "Installed mounted-volume lifecycle acceptance failed because the repository was not created on the mounted volume."
  fail "Mounted-volume repository was not created at $REPOSITORY_PATH"
fi

/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
DETACHED=1
if [[ -e "$REPOSITORY_PATH" ]]; then
  write_report "Installed mounted-volume lifecycle acceptance failed because the repository path was still visible after unmount."
  fail "Mounted-volume repository path was still visible after unmount: $REPOSITORY_PATH"
fi

{
  printf "# Delta Installed Mounted Volume Acceptance\n\n"
  printf -- "- Generated: %s UTC\n" "$TIMESTAMP"
  printf -- "- App: %s\n" "$APP_PATH"
  printf -- "- Volume name: %s\n" "$VOLUME_NAME"
  printf -- "- Mounted path: %s\n" "$MOUNT_POINT"
  printf -- "- Repository path: %s\n\n" "$REPOSITORY_PATH"
  printf "This verifies Delta's installed app lifecycle against a real mounted APFS volume under /Volumes. It does not replace manual SMB/NFS acceptance, but it proves the mounted-path code path uses Delta's coordinator, SQLite store, Keychain password command, bundled restic, destination preparation, browse, restore, check, cleanup, and prune behavior on a volume that can disappear from /Volumes.\n\n"
  printf "## Result\n\n"
  printf "Installed mounted-volume lifecycle acceptance passed.\n\n"
  printf -- "- Mounted under /Volumes: Yes\n"
  printf -- "- Repository created on mounted volume: Yes\n"
  printf -- "- Repository disappeared after unmount: Yes\n\n"
  printf "## Delta Lifecycle Output\n\n"
  printf '```text\n'
  /bin/cat "$STDOUT_FILE"
  printf '```\n'
} >"$OUTPUT"

LATEST_TMP="$OUTPUT_DIR/.installed-mounted-volume-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed mounted-volume acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed mounted-volume lifecycle acceptance passed for %s\n" "$APP_PATH"
