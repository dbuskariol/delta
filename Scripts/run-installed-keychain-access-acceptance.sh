#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_KEYCHAIN_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
SERVICE="com.delta.backup.destination-secrets"
TIMEOUT_SECONDS="${DELTA_KEYCHAIN_ACCEPTANCE_TIMEOUT_SECONDS:-8}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
AGENT="$APP_PATH/Contents/MacOS/DeltaAgent"
LEGACY_BRIDGE="$APP_PATH/Contents/MacOS/DeltaSecretBridge"
BRIDGE="$DELTA_EXECUTABLE"
for executable in "$DELTA_EXECUTABLE" "$AGENT" "$LEGACY_BRIDGE"; do
  if [[ ! -x "$executable" ]]; then
    printf "Required installed executable is missing or not executable: %s\n" "$executable" >&2
    exit 1
  fi
done

INFO_PLIST="$APP_PATH/Contents/Info.plist"

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || printf "Unknown"
}

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-keychain-access-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-keychain-access-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-keychain.XXXXXX)"
ACCOUNT="delta-acceptance-$TIMESTAMP-$(/usr/bin/uuidgen)"
SECRET="$(/usr/bin/uuidgen)-$(/usr/bin/uuidgen)"
STDOUT_FILE="$WORK_DIR/bridge.stdout"
STDERR_FILE="$WORK_DIR/bridge.stderr"
STATUS_FILE="$WORK_DIR/bridge.status"

cleanup() {
  DELTA_ENABLE_KEYCHAIN_ACCEPTANCE=1 \
    "$DELTA_EXECUTABLE" --acceptance-delete-secret "$ACCOUNT" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1 || true
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

run_bridge_with_timeout() {
  "$BRIDGE" --secret-bridge "$ACCOUNT" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
  local pid=$!
  local elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
      /bin/kill "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      printf "timeout" >"$STATUS_FILE"
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done

  local status=0
  wait "$pid" || status=$?
  printf "%s" "$status" >"$STATUS_FILE"
  return "$status"
}

cat >"$OUTPUT" <<EOF
# Delta Installed Keychain Access Acceptance

- Generated: $TIMESTAMP UTC
- App: $APP_PATH
- Bundle ID: $(plist_value CFBundleIdentifier)
- Version: $(plist_value CFBundleShortVersionString)
- Build: $(plist_value CFBundleVersion)
- Git Commit: $(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")
- Service: $SERVICE
- Account: $ACCOUNT
- Bridge: $BRIDGE --secret-bridge

This creates a throwaway destination-secret item through the installed Delta app, verifies the installed password bridge mode can read the item without interaction, and deletes the item on exit.

EOF

append_command_output() {
  local title="$1"
  shift
  {
    printf "## %s\n\n" "$title"
    printf '```text\n'
    "$@" 2>&1
    printf '```\n\n'
  } >>"$OUTPUT"
}

DELTA_ENABLE_KEYCHAIN_ACCEPTANCE=1 \
  "$DELTA_EXECUTABLE" --acceptance-delete-secret "$ACCOUNT" >/dev/null 2>&1 || true
/usr/bin/security delete-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1 || true
append_command_output "Add Throwaway Trusted Secret" \
  /usr/bin/env \
    DELTA_ENABLE_KEYCHAIN_ACCEPTANCE=1 \
    DELTA_KEYCHAIN_ACCEPTANCE_SECRET="$SECRET" \
    "$DELTA_EXECUTABLE" \
      --acceptance-save-secret \
      "$ACCOUNT"

if ! run_bridge_with_timeout; then
  {
    printf "## Bridge Read Failed\n\n"
    printf -- "- Exit status: %s\n" "$(/bin/cat "$STATUS_FILE" 2>/dev/null || printf "unknown")"
    printf -- "- Stdout bytes: %s\n" "$(/usr/bin/wc -c <"$STDOUT_FILE" | /usr/bin/tr -d ' ')"
    printf -- "- Stderr:\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >>"$OUTPUT"
  printf "Installed keychain access acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

read_secret="$(/bin/cat "$STDOUT_FILE" | /usr/bin/tr -d '\r\n')"
if [[ "$read_secret" != "$SECRET" ]]; then
  {
    printf "## Bridge Read Mismatch\n\n"
    printf "Bridge stdout did not match the saved secret.\n"
    printf -- "- Stdout bytes: %s\n" "$(/usr/bin/wc -c <"$STDOUT_FILE" | /usr/bin/tr -d ' ')"
    printf -- "- Stderr:\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >>"$OUTPUT"
  printf "Installed keychain access acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

stderr_bytes="$(/usr/bin/wc -c <"$STDERR_FILE" | /usr/bin/tr -d ' ')"
if [[ "$stderr_bytes" != "0" ]]; then
  {
    printf "## Bridge Stderr Was Not Empty\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >>"$OUTPUT"
  printf "Installed keychain access acceptance failed. See %s\n" "$OUTPUT" >&2
  exit 1
fi

cat >>"$OUTPUT" <<EOF
## Result

Installed keychain access acceptance passed.

- Bridge exit status: $(/bin/cat "$STATUS_FILE")
- Bridge stdout matched saved secret: Yes
- Bridge stderr bytes: $stderr_bytes
- Keychain item deleted on exit: Yes
EOF

LATEST_TMP="$OUTPUT_DIR/.installed-keychain-access-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed keychain access acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed keychain access acceptance passed for %s\n" "$APP_PATH"
