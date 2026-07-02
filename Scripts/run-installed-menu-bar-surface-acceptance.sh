#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_MENU_BAR_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-menu-bar-acceptance.XXXXXX)"
STDOUT_FILE="$WORK_DIR/menu-bar.stdout"
STDERR_FILE="$WORK_DIR/menu-bar.stderr"

cleanup() {
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

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-menu-bar-surface-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-menu-bar-surface-latest.md"

set +e
DELTA_ENABLE_MENU_BAR_ACCEPTANCE=1 \
  "$DELTA_EXECUTABLE" --acceptance-menu-bar-surface >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  fail "Installed menu bar surface acceptance failed." "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  fail "Installed menu bar surface acceptance failed because stderr was not empty."
fi

for expected in \
  "Installed menu bar surface acceptance passed." \
  "Ready status:" \
  "Running backup status:" \
  "Completed backup status:" \
  "Warning backup status:" \
  "Required actions:" \
  "Pause automatic runs leaves manual backup available: Yes" \
  "Active backup exposes Pause and Stop: Yes"
do
  if ! /usr/bin/grep -Fq "$expected" "$STDOUT_FILE"; then
    fail "Installed menu bar surface acceptance output was missing: $expected"
  fi
done

if /usr/bin/grep -Eiq "LaunchAgent|SMAppService|rawValue|restic|repository|Succeeded" "$STDOUT_FILE"; then
  fail "Installed menu bar surface acceptance exposed forbidden visible terminology."
fi

{
  printf "# Delta Installed Menu Bar Surface Acceptance\n\n"
  printf -- "- Generated: %s UTC\n" "$TIMESTAMP"
  printf -- "- App: %s\n\n" "$APP_PATH"
  printf "This verifies the installed app's shared status-menu surface contract without opening the native popover. Native visibility and persistent-popover behavior still require manual macOS interaction.\n\n"
  printf "## Result\n\n"
  printf "Installed menu bar surface acceptance passed.\n\n"
  printf "## Delta Output\n\n"
  printf '```text\n'
  /bin/cat "$STDOUT_FILE"
  printf '```\n'
} >"$OUTPUT"

LATEST_TMP="$OUTPUT_DIR/.installed-menu-bar-surface-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed menu bar surface acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed menu bar surface acceptance passed for %s\n" "$APP_PATH"
