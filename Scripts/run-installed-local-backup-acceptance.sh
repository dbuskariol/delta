#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_INSTALLED_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  printf "Delta executable is missing or not executable: %s\n" "$DELTA_EXECUTABLE" >&2
  exit 1
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-local-backup-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-local-backup-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-local-lifecycle.XXXXXX)"
STDOUT_FILE="$WORK_DIR/local-lifecycle.stdout"
STDERR_FILE="$WORK_DIR/local-lifecycle.stderr"
SUPPORT_DIR="$WORK_DIR/support"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

set +e
DELTA_ENABLE_LOCAL_LIFECYCLE_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
  "$DELTA_EXECUTABLE" --acceptance-local-lifecycle >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  {
    printf "# Delta Installed Local Lifecycle Acceptance\n\n"
    printf "Installed local lifecycle acceptance failed.\n\n"
    printf -- "- App: %s\n" "$APP_PATH"
    printf -- "- Exit status: %s\n\n" "$STATUS"
    printf "## Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n\n'
    printf "## Standard Output\n\n"
    printf '```text\n'
    /bin/cat "$STDOUT_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed local lifecycle acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  {
    printf "# Delta Installed Local Lifecycle Acceptance\n\n"
    printf "Installed local lifecycle acceptance failed because stderr was not empty.\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed local lifecycle acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

/bin/cp "$STDOUT_FILE" "$OUTPUT"
if ! /usr/bin/grep -Fq "Installed local lifecycle acceptance passed." "$OUTPUT"; then
  printf "Installed local lifecycle acceptance output did not contain the success marker.\n" >&2
  exit 1
fi
for expected in \
  "No-change backup:" \
  "Incremental backup:" \
  "Restore browser entries verified:" \
  "Selected folder restore status:" \
  "Selected file restore status:" \
  "Cleanup runs:"
do
  if ! /usr/bin/grep -Fq "$expected" "$OUTPUT"; then
    printf "Installed local lifecycle acceptance output was missing: %s\n" "$expected" >&2
    exit 1
  fi
done

LATEST_TMP="$OUTPUT_DIR/.installed-local-backup-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed local lifecycle acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed local lifecycle acceptance passed for %s\n" "$APP_PATH"
