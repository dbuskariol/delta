#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_PREFERENCES_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

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
OUTPUT="$OUTPUT_DIR/Delta-installed-preferences-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-preferences-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-preferences.XXXXXX)"
STDOUT_FILE="$WORK_DIR/preferences.stdout"
STDERR_FILE="$WORK_DIR/preferences.stderr"
SUPPORT_DIR="$WORK_DIR/support"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

set +e
DELTA_ENABLE_PREFERENCES_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
  "$DELTA_EXECUTABLE" --acceptance-preferences >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  {
    printf "# Delta Installed Preferences Acceptance\n\n"
    printf "Installed preferences acceptance failed.\n\n"
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
  printf "Installed preferences acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  {
    printf "# Delta Installed Preferences Acceptance\n\n"
    printf "Installed preferences acceptance failed because stderr was not empty.\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed preferences acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

/bin/cp "$STDOUT_FILE" "$OUTPUT"
if ! /usr/bin/grep -Fq "Installed preferences acceptance passed." "$OUTPUT"; then
  printf "Installed preferences acceptance output did not contain the success marker.\n" >&2
  exit 1
fi
for expected in \
  "Recommended backup defaults: Verified" \
  "Invalid preference normalization: Verified" \
  "Custom backup defaults persisted to a new profile: Verified" \
  "Custom restore defaults: Verified" \
  "Diagnostic preference summary: Verified" \
  "Existing preference values restored on exit: Yes"
do
  if ! /usr/bin/grep -Fq "$expected" "$OUTPUT"; then
    printf "Installed preferences acceptance output was missing: %s\n" "$expected" >&2
    exit 1
  fi
done

LATEST_TMP="$OUTPUT_DIR/.installed-preferences-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed preferences acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed preferences acceptance passed for %s\n" "$APP_PATH"
