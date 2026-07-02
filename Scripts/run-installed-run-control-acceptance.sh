#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_RUN_CONTROL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

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
OUTPUT="$OUTPUT_DIR/Delta-installed-run-control-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-run-control-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-run-control.XXXXXX)"
STDOUT_FILE="$WORK_DIR/run-control.stdout"
STDERR_FILE="$WORK_DIR/run-control.stderr"
SUPPORT_DIR="$WORK_DIR/support"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

set +e
DELTA_ENABLE_RUN_CONTROL_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
  "$DELTA_EXECUTABLE" --acceptance-run-control >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  {
    printf "# Delta Installed Run Control Acceptance\n\n"
    printf "Installed run-control acceptance failed.\n\n"
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
  printf "Installed run-control acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  {
    printf "# Delta Installed Run Control Acceptance\n\n"
    printf "Installed run-control acceptance failed because stderr was not empty.\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed run-control acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

/bin/cp "$STDOUT_FILE" "$OUTPUT"
if ! /usr/bin/grep -Fq "Installed run-control acceptance passed." "$OUTPUT"; then
  printf "Installed run-control acceptance output did not contain the success marker.\n" >&2
  exit 1
fi
for expected in \
  "Pause stop reason: pause" \
  "Paused backup remains resumable: Yes" \
  "Resume status: Completed" \
  "Cancel stop reason: cancel" \
  "Cancelled backup is resumable: No" \
  "Stop requests cleared: Yes" \
  "Command sequence: backup, backup, snapshots, backup"
do
  if ! /usr/bin/grep -Fq "$expected" "$OUTPUT"; then
    printf "Installed run-control acceptance output was missing: %s\n" "$expected" >&2
    exit 1
  fi
done

LATEST_TMP="$OUTPUT_DIR/.installed-run-control-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed run-control acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed run-control acceptance passed for %s\n" "$APP_PATH"
