#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_SCHEDULED_AGENT_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
SERVICE="com.delta.backup.destination-secrets"
PREFERENCES_DOMAIN="com.delta.backup.preferences"
PAUSE_KEY="Delta.pausesScheduledBackups"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
AGENT="$APP_PATH/Contents/Resources/DeltaAgent"
for executable in "$DELTA_EXECUTABLE" "$AGENT"; do
  if [[ ! -x "$executable" ]]; then
    printf "Required installed executable is missing or not executable: %s\n" "$executable" >&2
    exit 1
  fi
done

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-scheduled-agent-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-scheduled-agent-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-scheduled-agent.XXXXXX)"
SUPPORT_DIR="$WORK_DIR/support"
ACCOUNT="delta-scheduled-agent-$TIMESTAMP-$(/usr/bin/uuidgen)"
SEED_STDOUT="$WORK_DIR/seed.stdout"
SEED_STDERR="$WORK_DIR/seed.stderr"
AGENT_STDOUT="$WORK_DIR/agent.stdout"
AGENT_STDERR="$WORK_DIR/agent.stderr"
VERIFY_STDOUT="$WORK_DIR/verify.stdout"
VERIFY_STDERR="$WORK_DIR/verify.stderr"
ORIGINAL_PAUSE_VALUE="$(/usr/bin/defaults read "$PREFERENCES_DOMAIN" "$PAUSE_KEY" 2>/dev/null || true)"
ORIGINAL_PAUSE_WAS_SET=0
if [[ -n "$ORIGINAL_PAUSE_VALUE" ]]; then
  ORIGINAL_PAUSE_WAS_SET=1
fi

cleanup() {
  DELTA_ENABLE_KEYCHAIN_ACCEPTANCE=1 \
    "$DELTA_EXECUTABLE" --acceptance-delete-secret "$ACCOUNT" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1 || true

  if [[ "$ORIGINAL_PAUSE_WAS_SET" == "1" ]]; then
    case "$ORIGINAL_PAUSE_VALUE" in
      1|true|TRUE|yes|YES)
        /usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool true >/dev/null
        ;;
      0|false|FALSE|no|NO)
        /usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool false >/dev/null
        ;;
      *)
        printf 'Could not restore unexpected Scheduled Backups pause value: %s\n' "$ORIGINAL_PAUSE_VALUE" >&2
        ;;
    esac
  else
    /usr/bin/defaults delete "$PREFERENCES_DOMAIN" "$PAUSE_KEY" >/dev/null 2>&1 || true
  fi

  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

write_failure_report() {
  local title="$1"
  local status="$2"
  {
    printf "# Delta Installed Scheduled Backups Acceptance\n\n"
    printf "%s\n\n" "$title"
    printf -- "- App: %s\n" "$APP_PATH"
    printf -- "- Exit status: %s\n" "$status"
    printf -- "- Application Support: %s\n" "$SUPPORT_DIR"
    printf -- "- Keychain account: %s\n\n" "$ACCOUNT"
    printf "## Seed Standard Output\n\n"
    printf '```text\n'
    /bin/cat "$SEED_STDOUT" 2>/dev/null || true
    printf '```\n\n'
    printf "## Seed Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$SEED_STDERR" 2>/dev/null || true
    printf '```\n\n'
    printf "## Agent Standard Output\n\n"
    printf '```text\n'
    /bin/cat "$AGENT_STDOUT" 2>/dev/null || true
    printf '```\n\n'
    printf "## Agent Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$AGENT_STDERR" 2>/dev/null || true
    printf '```\n\n'
    printf "## Verify Standard Output\n\n"
    printf '```text\n'
    /bin/cat "$VERIFY_STDOUT" 2>/dev/null || true
    printf '```\n\n'
    printf "## Verify Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$VERIFY_STDERR" 2>/dev/null || true
    printf '```\n'
  } >"$OUTPUT"
}

set +e
DELTA_ENABLE_SCHEDULED_AGENT_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
  "$DELTA_EXECUTABLE" --acceptance-seed-scheduled-agent "$WORK_DIR" "$ACCOUNT" >"$SEED_STDOUT" 2>"$SEED_STDERR"
SEED_STATUS=$?
set -e
if [[ "$SEED_STATUS" -ne 0 ]]; then
  write_failure_report "Installed Scheduled Backups acceptance failed while seeding isolated state." "$SEED_STATUS"
  printf "Installed Scheduled Backups acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$SEED_STATUS"
fi

# The acceptance profile is isolated, but the scheduler pause preference is shared
# with the installed app. Temporarily resume scheduled work and restore the exact
# prior preference in cleanup so a user's paused state cannot invalidate the probe.
/usr/bin/defaults write "$PREFERENCES_DOMAIN" "$PAUSE_KEY" -bool false >/dev/null

set +e
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" "$AGENT" >"$AGENT_STDOUT" 2>"$AGENT_STDERR"
AGENT_STATUS=$?
set -e
if [[ "$AGENT_STATUS" -ne 0 ]]; then
  write_failure_report "Installed Scheduled Backups acceptance failed while running DeltaAgent." "$AGENT_STATUS"
  printf "Installed Scheduled Backups acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$AGENT_STATUS"
fi
if ! /usr/bin/grep -Fq "completed 1 due backup run(s)" "$AGENT_STDOUT"; then
  write_failure_report "Installed Scheduled Backups acceptance failed because DeltaAgent did not report one due backup." "$AGENT_STATUS"
  printf "Installed Scheduled Backups acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

set +e
DELTA_ENABLE_SCHEDULED_AGENT_ACCEPTANCE=1 \
DELTA_APP_SUPPORT_DIR="$SUPPORT_DIR" \
  "$DELTA_EXECUTABLE" --acceptance-verify-scheduled-agent "$WORK_DIR" "$ACCOUNT" >"$VERIFY_STDOUT" 2>"$VERIFY_STDERR"
VERIFY_STATUS=$?
set -e
if [[ "$VERIFY_STATUS" -ne 0 ]]; then
  write_failure_report "Installed Scheduled Backups acceptance failed while verifying the scheduled backup." "$VERIFY_STATUS"
  printf "Installed Scheduled Backups acceptance failed. See %s\n" "$OUTPUT" >&2
  exit "$VERIFY_STATUS"
fi

if [[ -s "$VERIFY_STDERR" ]]; then
  write_failure_report "Installed Scheduled Backups acceptance failed because verify stderr was not empty." 1
  printf "Installed Scheduled Backups acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

/bin/cp "$VERIFY_STDOUT" "$OUTPUT"
{
  printf "\n## Seed Output\n\n"
  printf '```text\n'
  /bin/cat "$SEED_STDOUT"
  printf '```\n\n'
  printf "## Agent Output\n\n"
  printf '```text\n'
  /bin/cat "$AGENT_STDOUT"
  printf '```\n'
} >>"$OUTPUT"

for expected in \
  "Installed Scheduled Backups acceptance passed." \
  "Scheduler-started backup status:" \
  "Automatic destination preparation jobs:" \
  "Cached restore points:" \
  "Source context logged: Yes"
do
  if ! /usr/bin/grep -Fq "$expected" "$OUTPUT"; then
    printf "Installed Scheduled Backups acceptance output was missing: %s\n" "$expected" >&2
    exit 1
  fi
done

LATEST_TMP="$OUTPUT_DIR/.installed-scheduled-agent-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed Scheduled Backups acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed Scheduled Backups acceptance passed for %s\n" "$APP_PATH"
